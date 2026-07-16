import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:infrastructure/src/db/postgres_connection.dart';
// `postgres` exports its own `Result`; we only need its exception hierarchy
// here (to read the SQLSTATE `code`/`constraintName` off a `ServerException`),
// so hide `Result` to keep `Result<T>` unambiguously our `shared` union.
import 'package:postgres/postgres.dart' hide Result;
import 'package:shared/shared.dart';

/// Postgres-backed [LedgerRepository] over the append-only
/// `ledger.point_entries` table (Database ADR; migration `0005_ledger.sql`).
///
/// The ledger is the **protected competitive record** (Axiom 5): entries are
/// only ever *appended*, never edited or deleted. This adapter therefore issues
/// exactly one kind of write — an INSERT — and offers no UPDATE/DELETE path (the
/// migration additionally revokes UPDATE/DELETE and installs an immutability
/// trigger as the backstop, Axiom 6).
///
/// The adapter is *total* (Application ADR §2): it never throws. It speaks only
/// in the domain [PointEntry] aggregate, the [LedgerBalance] projection, and
/// typed ids; SQL and rows never leak.
///
/// **Atomicity + idempotency** (Axioms 4/5): [appendEntries] inserts the whole
/// batch inside a single [PostgresConnection.runInTransaction] — a mid-write
/// failure rolls the whole post back, so the record is never half-written. A
/// `round_score` credit is deduped on the natural key `(participant_id,
/// round_id, entry_kind)` via `ON CONFLICT DO NOTHING` against the partial
/// unique index `point_entries_round_score_uniq`; the `RETURNING` clause reports
/// only the rows actually inserted, so a re-post appends nothing new and never
/// double-credits. A `correction` entry is intentionally append-many (it does
/// not participate in the partial index), so multiple corrections coexist.
///
/// **Balance is a projection** (Axiom 5): [balanceFor] computes the signed sum
/// with `COALESCE(SUM(amount), 0)` over the participant's stream — never a
/// stored mutable total — and its value equals the domain `LedgerBalance.project`
/// over [listEntries].
///
/// All queries bind values through `@named` parameters (Security ADR §2).
final class PostgresLedgerRepository implements LedgerRepository {
  /// Creates the repository over an open [PostgresConnection].
  const PostgresLedgerRepository(this._connection);

  final PostgresConnection _connection;

  // --------------------------------------------------------------------------
  // appendEntries — atomic, idempotent, append-only batch insert
  // --------------------------------------------------------------------------

  // ON CONFLICT DO NOTHING against the partial unique index restricted to the
  // deduped `round_score` kind: a re-post of an already-present
  // (participant, round, round_score) credit inserts no row and RETURNS nothing,
  // so it can never double-credit (Axiom 4). A `correction` is not covered by
  // that partial index, so it always inserts (append-many). The RETURNING clause
  // lets the adapter report exactly which rows this call appended.
  static const String _insertEntrySql = '''
INSERT INTO ledger.point_entries
  (id, participant_id, round_id, entry_kind, amount, source_ref, occurred_at)
VALUES
  (@id, @participant_id, @round_id, @entry_kind, @amount, @source_ref, @occurred_at)
ON CONFLICT ON CONSTRAINT point_entries_round_score_uniq DO NOTHING
RETURNING id, participant_id, round_id, entry_kind, amount, source_ref, occurred_at
''';

  @override
  Future<Result<List<PointEntry>>> appendEntries(List<PointEntry> entries) {
    if (entries.isEmpty) {
      // A round with no scored participants posts nothing; avoid opening a
      // transaction for a no-op.
      return Future.value(const Result.ok(<PointEntry>[]));
    }
    // The whole batch in ONE transaction: a failure on any insert rolls the
    // entire post back, so the append-only stream is never half-written
    // (Axiom 5).
    return _connection.runInTransaction((tx) async {
      final appended = <PointEntry>[];
      for (final entry in entries) {
        final inserted = await tx.query(
          _insertEntrySql,
          parameters: {
            'id': entry.id.value,
            'participant_id': entry.participantId.value,
            'round_id': entry.roundId.value,
            'entry_kind': entry.kind.wireValue,
            'amount': entry.amount,
            'source_ref': entry.sourceRef,
            'occurred_at': entry.occurredAt.toUtc(),
          },
        );
        switch (inserted) {
          case Err<List<Map<String, dynamic>>>(:final error):
            // Rolls the transaction back (runInTransaction converts an Err into
            // a rollback), reclassifying a storage-integrity conflict.
            return Result.err(_reclassify(error));
          case Ok<List<Map<String, dynamic>>>(:final value):
            // Empty ⇒ the row already existed (deduped skip): append nothing.
            if (value.isEmpty) {
              continue;
            }
            final mapped = _mapEntry(value.first);
            if (mapped is Err<PointEntry>) {
              return Result.err(mapped.error);
            }
            appended.add((mapped as Ok<PointEntry>).value);
        }
      }
      return Result.ok(List<PointEntry>.unmodifiable(appended));
    });
  }

  // --------------------------------------------------------------------------
  // listEntries — a participant's append-only stream (occurred-at then id)
  // --------------------------------------------------------------------------

  static const String _selectByParticipantSql = '''
SELECT id, participant_id, round_id, entry_kind, amount, source_ref, occurred_at
FROM ledger.point_entries
WHERE participant_id = @participant_id
ORDER BY occurred_at ASC, id ASC
''';

  @override
  Future<Result<List<PointEntry>>> listEntries(
    ParticipantId participantId,
  ) async {
    final result = await _connection.query(
      _selectByParticipantSql,
      parameters: {'participant_id': participantId.value},
    );
    return switch (result) {
      Err<List<Map<String, dynamic>>>(:final error) => Result.err(error),
      Ok<List<Map<String, dynamic>>>(:final value) => _mapEntries(value),
    };
  }

  // --------------------------------------------------------------------------
  // balanceFor — projection (never a stored mutable total)
  // --------------------------------------------------------------------------

  @override
  Future<Result<LedgerBalance>> balanceFor(ParticipantId participantId) async {
    // The port guarantees `balanceFor == LedgerBalance.project(listEntries)`
    // (a balance is a *projection* over the append-only stream — Axiom 5, never
    // a stored mutable total). We honour that literally: read the participant's
    // stream and reduce it with the pure domain projection, so the balance can
    // never drift from the entries it claims to summarize. The stream is a
    // participant's own ledger (bounded by their round participation), so the
    // read is cheap; a future scale phase MAY back this with a materialized
    // `COALESCE(SUM(amount), 0)` view, but only if it provably equals this
    // reduction.
    final entriesResult = await listEntries(participantId);
    if (entriesResult is Err<List<PointEntry>>) {
      return Result.err(entriesResult.error);
    }
    final entries = (entriesResult as Ok<List<PointEntry>>).value;
    return LedgerBalance.project(
      participantId: participantId,
      entries: entries,
    );
  }

  // --------------------------------------------------------------------------
  // Row mapping
  // --------------------------------------------------------------------------

  Result<List<PointEntry>> _mapEntries(List<Map<String, dynamic>> rows) {
    final entries = <PointEntry>[];
    for (final row in rows) {
      final mapped = _mapEntry(row);
      if (mapped is Err<PointEntry>) {
        return Result.err(mapped.error);
      }
      entries.add((mapped as Ok<PointEntry>).value);
    }
    return Result.ok(List<PointEntry>.unmodifiable(entries));
  }

  Result<PointEntry> _mapEntry(Map<String, dynamic> row) {
    final idResult = PointEntryId.tryParse(row['id']?.toString());
    final participantIdResult = ParticipantId.tryParse(
      row['participant_id']?.toString(),
    );
    final roundIdResult = RoundId.tryParse(row['round_id']?.toString());
    final kindResult = EntryKind.tryParse(row['entry_kind']?.toString());
    final amount = _readInt(row['amount']);
    final sourceRefRaw = row['source_ref'];
    final occurredAt = _readUtcTimestamp(row['occurred_at']);

    if (idResult is Err<PointEntryId>) {
      return Result.err(
        _corrupt('point_entries', 'id', idResult.error.message),
      );
    }
    if (participantIdResult is Err<ParticipantId>) {
      return Result.err(
        _corrupt(
          'point_entries',
          'participant_id',
          participantIdResult.error.message,
        ),
      );
    }
    if (roundIdResult is Err<RoundId>) {
      return Result.err(
        _corrupt('point_entries', 'round_id', roundIdResult.error.message),
      );
    }
    if (kindResult is Err<EntryKind>) {
      return Result.err(
        _corrupt('point_entries', 'entry_kind', kindResult.error.message),
      );
    }
    if (amount == null) {
      return Result.err(_corrupt('point_entries', 'amount', 'not an integer'));
    }
    if (sourceRefRaw is! String || sourceRefRaw.isEmpty) {
      return Result.err(
        _corrupt('point_entries', 'source_ref', 'null or empty'),
      );
    }
    if (occurredAt == null) {
      return Result.err(
        _corrupt('point_entries', 'occurred_at', 'not a timestamp'),
      );
    }

    return Result.ok(
      PointEntry.fromStored(
        id: (idResult as Ok<PointEntryId>).value,
        participantId: (participantIdResult as Ok<ParticipantId>).value,
        roundId: (roundIdResult as Ok<RoundId>).value,
        kind: (kindResult as Ok<EntryKind>).value,
        amount: amount,
        sourceRef: sourceRefRaw,
        occurredAt: occurredAt,
      ),
    );
  }

  // --------------------------------------------------------------------------
  // Shared helpers (mirror the scoring/competition adapters)
  // --------------------------------------------------------------------------

  AppError _reclassify(AppError error) {
    final cause = error.cause;
    if (cause is! ServerException) {
      return error;
    }
    final code = cause.code;
    // 23505 unique_violation (a race that slipped past ON CONFLICT — should not
    // happen for the round_score partial index, but map it defensively rather
    // than surface a raw transient), 23503 foreign_key_violation (round or
    // participant vanished), 23514 check_violation (the immutability trigger or
    // an amount/source_ref check).
    const integrityCodes = {'23505', '23503', '23514'};
    if (code == null || !integrityCodes.contains(code)) {
      return error;
    }
    final constraint = cause.constraintName;
    if (constraint == 'point_entries_round_id_fkey') {
      return const AppError.invariant(
        'ledger.round_not_found',
        'Round not found',
      );
    }
    if (constraint == 'point_entries_participant_id_fkey') {
      return const AppError.invariant(
        'ledger.participant_not_found',
        'Participant not found',
      );
    }
    if (constraint == 'point_entries_round_score_uniq') {
      // A concurrent duplicate credit lost the race — the record is intact
      // (the other writer's row stands), so report the idempotent conflict.
      return const AppError.invariant(
        'ledger.already_posted',
        'This round-score credit was already appended',
      );
    }
    return const AppError.invariant(
      'ledger.integrity_violation',
      'The write violated a ledger integrity rule',
    );
  }

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

  static AppError _corrupt(String table, String field, String detail) =>
      AppError.transient(
        'ledger.row_corrupt',
        'Stored $table row has invalid $field: $detail',
      );
}
