import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:infrastructure/src/db/postgres_connection.dart';
import 'package:shared/shared.dart';

/// Postgres-backed [ParticipantReader] over the `competition.participants` table
/// (Database ADR; migration `0002_competition.sql`).
///
/// The Ledger read use-case gates on **self-read** — a caller may read only a
/// participant they own — but is keyed by participant id (the wire surface is
/// `GET /participants/{id}/…`). The frozen `CompetitionRepository` offers no
/// by-id lookup and must not change without approval, so the Ledger slice owns
/// this narrow read port; here it is implemented as a single, read-only
/// `SELECT … WHERE id = …` against the same participants row the competition
/// adapter writes. It performs **no** write and touches only Competition's own
/// table (a read of another context's data is permitted; a mutation would not
/// be).
///
/// The adapter is *total* (Application ADR §2): it never throws. It speaks only
/// in the domain [Participant] aggregate and typed ids; SQL and rows never leak.
/// A row that cannot be decoded is reported as a transient
/// `ledger.row_corrupt`, matching the other adapters' schema-drift discipline.
///
/// All queries bind values through `@named` parameters (Security ADR §2).
final class PostgresParticipantReader implements ParticipantReader {
  /// Creates the reader over an open [PostgresConnection].
  const PostgresParticipantReader(this._connection);

  final PostgresConnection _connection;

  static const String _selectByIdSql = '''
SELECT id, season_id, user_id, status, joined_at
FROM competition.participants
WHERE id = @id
''';

  @override
  Future<Result<Participant?>> findParticipantById(ParticipantId id) async {
    final result = await _connection.query(
      _selectByIdSql,
      parameters: {'id': id.value},
    );
    return switch (result) {
      Err<List<Map<String, dynamic>>>(:final error) => Result.err(error),
      // Absence is a normal, successful "no such participant" outcome
      // (Ok(null)); the use-case reports it as not-found without leaking
      // whether the id belongs to another user.
      Ok<List<Map<String, dynamic>>>(:final value) =>
        value.isEmpty ? const Result.ok(null) : _mapParticipant(value.first),
    };
  }

  Result<Participant?> _mapParticipant(Map<String, dynamic> row) {
    final idResult = ParticipantId.tryParse(row['id']?.toString());
    final seasonIdResult = SeasonId.tryParse(row['season_id']?.toString());
    final userIdResult = UserId.tryParse(row['user_id']?.toString());
    final statusResult = ParticipantStatus.tryParse(row['status']?.toString());
    final joinedAt = _readUtcTimestamp(row['joined_at']);

    if (idResult is Err<ParticipantId>) {
      return Result.err(_corrupt('participants', 'id', idResult.error.message));
    }
    if (seasonIdResult is Err<SeasonId>) {
      return Result.err(
        _corrupt('participants', 'season_id', seasonIdResult.error.message),
      );
    }
    if (userIdResult is Err<UserId>) {
      return Result.err(
        _corrupt('participants', 'user_id', userIdResult.error.message),
      );
    }
    if (statusResult is Err<ParticipantStatus>) {
      return Result.err(
        _corrupt('participants', 'status', statusResult.error.message),
      );
    }
    if (joinedAt == null) {
      return Result.err(
        _corrupt('participants', 'joined_at', 'not a timestamp'),
      );
    }

    return Result.ok(
      Participant.fromStored(
        id: (idResult as Ok<ParticipantId>).value,
        seasonId: (seasonIdResult as Ok<SeasonId>).value,
        userId: (userIdResult as Ok<UserId>).value,
        status: (statusResult as Ok<ParticipantStatus>).value,
        joinedAt: joinedAt,
      ),
    );
  }

  static DateTime? _readUtcTimestamp(Object? raw) {
    if (raw is DateTime) {
      return raw.toUtc();
    }
    if (raw is String) {
      final parsed = DateTime.tryParse(raw);
      return parsed?.toUtc();
    }
    return null;
  }

  static AppError _corrupt(String table, String field, String detail) =>
      AppError.transient(
        'ledger.row_corrupt',
        'Stored $table row has invalid $field: $detail',
      );
}
