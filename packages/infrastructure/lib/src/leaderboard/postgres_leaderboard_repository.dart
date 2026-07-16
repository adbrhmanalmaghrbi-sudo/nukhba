import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:infrastructure/src/db/postgres_connection.dart';
import 'package:shared/shared.dart';

/// Postgres-backed [LeaderboardRepository] over the season-scoped projection
/// VIEW `leaderboard.season_standings` (Database ADR; migration
/// `0006_leaderboard.sql`).
///
/// A leaderboard is a **read-side projection** over the ratified append-only
/// ledger (Axiom 5; Leaderboards architecture decision in project-context §2) —
/// NEVER a second source of truth for points. This adapter therefore issues a
/// single read: a `SELECT` over the VIEW, which is itself a
/// `SUM(amount) … GROUP BY participant` over a season-scoped join of
/// `ledger.point_entries` → `competition.rounds` (to bound the sum to the
/// season) LEFT-joined from `competition.participants` (so an enrolled-but-
/// never-credited participant still appears with a zero total). The adapter
/// carries no ranking logic: it returns **unranked** entries; the total order
/// (points desc, joinedAt asc, participant-id asc) and standard-competition
/// ("1224") ranks are applied by the pure domain [SeasonLeaderboard.rank] in
/// the use-case, so the ranking rule is framework-free and identical whoever
/// runs the query.
///
/// The adapter is *total* (Application ADR §2): it never throws. It speaks only
/// in the domain [LeaderboardEntry] and typed ids; SQL and rows never leak. A
/// driver failure is surfaced as [ErrorKind.transient]; a malformed row is
/// mapped to a transient `leaderboard.row_corrupt`. All queries bind values
/// through `@named` parameters (Security ADR §2).
final class PostgresLeaderboardRepository implements LeaderboardRepository {
  /// Creates the repository over an open [PostgresConnection].
  const PostgresLeaderboardRepository(this._connection);

  final PostgresConnection _connection;

  // Read the season's standings from the projection VIEW. The VIEW already
  // scopes the SUM to the season (via the round→season join inside it) and
  // LEFT-joins from participants, so every ACTIVE/WITHDRAWN participant of the
  // season appears exactly once — a never-credited one with total 0, count 0.
  // The order here is unspecified on purpose (the domain sorts + ranks); we do
  // not ORDER BY in SQL so the ranking rule lives in exactly one place.
  static const String _selectSeasonStandingsSql = '''
SELECT participant_id, total_points, entry_count, joined_at
FROM leaderboard.season_standings
WHERE season_id = @season_id
''';

  @override
  Future<Result<List<LeaderboardEntry>>> seasonStandings(
    SeasonId seasonId,
  ) async {
    final result = await _connection.query(
      _selectSeasonStandingsSql,
      parameters: {'season_id': seasonId.value},
    );
    return switch (result) {
      Err<List<Map<String, dynamic>>>(:final error) => Result.err(error),
      Ok<List<Map<String, dynamic>>>(:final value) => _mapEntries(value),
    };
  }

  // --------------------------------------------------------------------------
  // Row mapping
  // --------------------------------------------------------------------------

  Result<List<LeaderboardEntry>> _mapEntries(List<Map<String, dynamic>> rows) {
    final entries = <LeaderboardEntry>[];
    for (final row in rows) {
      final mapped = _mapEntry(row);
      if (mapped is Err<LeaderboardEntry>) {
        return Result.err(mapped.error);
      }
      entries.add((mapped as Ok<LeaderboardEntry>).value);
    }
    return Result.ok(List<LeaderboardEntry>.unmodifiable(entries));
  }

  Result<LeaderboardEntry> _mapEntry(Map<String, dynamic> row) {
    final participantIdResult = ParticipantId.tryParse(
      row['participant_id']?.toString(),
    );
    final totalPoints = _readInt(row['total_points']);
    final entryCount = _readInt(row['entry_count']);
    final joinedAt = _readUtcTimestamp(row['joined_at']);

    if (participantIdResult is Err<ParticipantId>) {
      return Result.err(
        _corrupt(
          'season_standings',
          'participant_id',
          participantIdResult.error.message,
        ),
      );
    }
    if (totalPoints == null) {
      return Result.err(
        _corrupt('season_standings', 'total_points', 'not an integer'),
      );
    }
    if (entryCount == null) {
      return Result.err(
        _corrupt('season_standings', 'entry_count', 'not an integer'),
      );
    }
    if (joinedAt == null) {
      return Result.err(
        _corrupt('season_standings', 'joined_at', 'not a timestamp'),
      );
    }

    // The domain enforces the residual invariants (entryCount >= 0, joinedAt
    // UTC). A projected() Err means the stored projection is inconsistent with
    // the domain rule, so reclassify it as a corrupt-row transient rather than
    // leak a raw invariant/validation out of a read path.
    final projected = LeaderboardEntry.projected(
      participantId: (participantIdResult as Ok<ParticipantId>).value,
      totalPoints: totalPoints,
      entryCount: entryCount,
      joinedAt: joinedAt,
    );
    if (projected is Err<LeaderboardEntry>) {
      return Result.err(
        _corrupt('season_standings', 'row', projected.error.message),
      );
    }
    return projected;
  }

  // --------------------------------------------------------------------------
  // Shared helpers (mirror the ledger/scoring/competition adapters)
  // --------------------------------------------------------------------------

  static int? _readInt(Object? raw) {
    if (raw is int) {
      return raw;
    }
    if (raw is BigInt && raw.isValidInt) {
      return raw.toInt();
    }
    if (raw is String) {
      return int.tryParse(raw);
    }
    return null;
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

  static AppError _corrupt(String view, String field, String detail) =>
      AppError.transient(
        'leaderboard.row_corrupt',
        'Stored $view row has invalid $field: $detail',
      );
}
