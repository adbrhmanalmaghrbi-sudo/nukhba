import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:infrastructure/src/db/postgres_connection.dart';
import 'package:infrastructure/src/ledger/postgres_ledger_repository.dart';
import 'package:infrastructure/src/ledger/postgres_participant_reader.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

/// Hermetic unit tests for the Ledger infrastructure adapters
/// ([PostgresLedgerRepository] and [PostgresParticipantReader]).
///
/// These do NOT require a live database. They substitute a fake
/// [PostgresConnection] that replies to each successive `query` with the next
/// scripted [Result] (and models `runInTransaction` by running the action's
/// statements against the same fake), so we can drive every *pure* branch the
/// adapters own:
///   * `point_entries` append: the INSERT parameter-binding (UTC occurred_at,
///     kind wire token), the `RETURNING`-driven "actually appended" subset,
///     the deduped skip (empty RETURNING ⇒ omitted, no double-count), the
///     empty-batch no-op, the verbatim pass-through of a mid-transaction
///     failure, and row-corruption mapping;
///   * `listEntries` mapping + ordering-clause presence, and `balanceFor`
///     computed as the domain projection over the stream (zero on empty);
///   * `participants` by-id read: `Ok(null)` when absent, mapped participant,
///     row-corruption mapping.
///
/// The one branch that genuinely needs the driver — reclassifying a `postgres`
/// [ServerException] into a domain `invariant` conflict via the SQLSTATE
/// `code`/`constraintName` (`ledger.round_not_found`,
/// `ledger.participant_not_found`, `ledger.already_posted`,
/// `ledger.integrity_violation`) — is deliberately NOT exercised here: the
/// driver's `ServerException` has no public constructor, so that path can only
/// be verified honestly against real Postgres (see the DB-gated
/// `postgres_ledger_repositories_integration_test.dart`).

const _entryId = '11111111-1111-1111-1111-111111111111';
const _entryId2 = '99999999-9999-9999-9999-999999999999';
const _participantId = '22222222-2222-2222-2222-222222222222';
const _roundId = '33333333-3333-3333-3333-333333333333';
const _seasonId = '55555555-5555-5555-5555-555555555555';
const _userId = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee';

/// A [PostgresConnection] test double that replays a scripted queue of
/// [Result]s (one per `query`) and records every SQL + parameter set it saw.
final class _FakeConnection implements PostgresConnection {
  _FakeConnection(this._responses);

  final List<Result<List<Map<String, dynamic>>>> _responses;
  int _index = 0;

  final List<String> sqls = [];
  final List<Map<String, Object?>> parameters = [];

  @override
  Future<Result<List<Map<String, dynamic>>>> query(
    String sql, {
    Map<String, Object?> parameters = const {},
  }) async {
    sqls.add(sql);
    this.parameters.add(parameters);
    final response =
        _responses[_index < _responses.length ? _index : _responses.length - 1];
    _index++;
    return response;
  }

  @override
  Future<Result<bool>> ping() async => const Result.ok(true);

  @override
  Future<Result<T>> runInTransaction<T>(
    Future<Result<T>> Function(DbExecutor tx) action,
  ) async {
    // Faithfully model the transaction contract against the scripted queue: the
    // action runs against this same fake (each `query` consumes the next
    // response), an Ok commits, an Err "rolls back" — the outcome is returned
    // verbatim, preserving the adapter's SQLSTATE→invariant reclassification.
    return action(this);
  }

  @override
  Future<void> close() async {}
}

_FakeConnection _rows(List<Map<String, dynamic>> rows) =>
    _FakeConnection([Result.ok(rows)]);

_FakeConnection _script(List<Result<List<Map<String, dynamic>>>> responses) =>
    _FakeConnection(responses);

_FakeConnection _fails() => _FakeConnection([
  const Result.err(
    AppError.transient('db.query_failed', 'Database query failed'),
  ),
]);

ParticipantId get _pId =>
    (ParticipantId.tryParse(_participantId) as Ok<ParticipantId>).value;

PointEntry _entry({
  String id = _entryId,
  String participant = _participantId,
  String round = _roundId,
  EntryKind kind = EntryKind.roundScore,
  int amount = 4,
  String? sourceRef,
  DateTime? occurredAt,
}) => PointEntry.fromStored(
  id: PointEntryId(id),
  participantId: ParticipantId(participant),
  roundId: RoundId(round),
  kind: kind,
  amount: amount,
  sourceRef: sourceRef ?? 'round_score:$round:$participant',
  occurredAt: occurredAt ?? DateTime.utc(2026, 7, 11, 12),
);

Map<String, dynamic> _entryRow({
  String id = _entryId,
  String participant = _participantId,
  String round = _roundId,
  String kind = 'round_score',
  int amount = 4,
  String? sourceRef,
  Object occurredAt = '2026-07-11T12:00:00.000Z',
}) => {
  'id': id,
  'participant_id': participant,
  'round_id': round,
  'entry_kind': kind,
  'amount': amount,
  'source_ref': sourceRef ?? 'round_score:$round:$participant',
  'occurred_at': occurredAt,
};

Map<String, dynamic> _participantRow({
  String id = _participantId,
  String season = _seasonId,
  String user = _userId,
  String status = 'active',
  Object joinedAt = '2026-07-01T00:00:00.000Z',
}) => {
  'id': id,
  'season_id': season,
  'user_id': user,
  'status': status,
  'joined_at': joinedAt,
};

void main() {
  group('PostgresLedgerRepository.appendEntries', () {
    test('is a no-op for an empty batch (no transaction/query)', () async {
      final conn = _rows(const []);
      final repo = PostgresLedgerRepository(conn);

      final result = await repo.appendEntries(const []);

      expect(result, isA<Ok<List<PointEntry>>>());
      expect((result as Ok<List<PointEntry>>).value, isEmpty);
      expect(conn.sqls, isEmpty);
    });

    test(
      'inserts an append-only row and binds kind token + UTC occurred_at',
      () async {
        // The RETURNING clause echoes the inserted row back.
        final conn = _script([
          Result.ok([_entryRow()]),
        ]);
        final repo = PostgresLedgerRepository(conn);

        final result = await repo.appendEntries([_entry()]);

        expect(result, isA<Ok<List<PointEntry>>>());
        final appended = (result as Ok<List<PointEntry>>).value;
        expect(appended.length, 1);
        expect(appended.single.id, const PointEntryId(_entryId));
        expect(appended.single.kind, EntryKind.roundScore);
        expect(appended.single.amount, 4);
        // The insert never carries an UPDATE/DELETE — append-only.
        expect(conn.sqls.single, contains('INSERT INTO ledger.point_entries'));
        expect(
          conn.sqls.single,
          contains(
            'ON CONFLICT ON CONSTRAINT point_entries_round_score_uniq DO NOTHING',
          ),
        );
        expect(conn.sqls.single, contains('RETURNING'));
        expect(conn.sqls.single, isNot(contains('UPDATE')));
        expect(conn.sqls.single, isNot(contains('DELETE')));
        expect(conn.parameters.single['entry_kind'], 'round_score');
        expect(conn.parameters.single['amount'], 4);
        // occurred_at bound as a UTC DateTime.
        final boundOccurred = conn.parameters.single['occurred_at'];
        expect(boundOccurred, isA<DateTime>());
        expect((boundOccurred! as DateTime).isUtc, isTrue);
      },
    );

    test(
      'a deduped skip (empty RETURNING) is omitted, never double-counted',
      () async {
        // Two credits: first inserts (returns a row), second is a dup (returns
        // nothing because ON CONFLICT DO NOTHING).
        final conn = _script([
          Result.ok([_entryRow(id: _entryId)]),
          const Result.ok(<Map<String, dynamic>>[]),
        ]);
        final repo = PostgresLedgerRepository(conn);

        final result = await repo.appendEntries([
          _entry(id: _entryId),
          _entry(id: _entryId2), // same (participant, round, kind) → skipped
        ]);

        expect(result, isA<Ok<List<PointEntry>>>());
        final appended = (result as Ok<List<PointEntry>>).value;
        // Only the row actually inserted is reported (Axiom 4: no double-credit).
        expect(appended.length, 1);
        expect(appended.single.id, const PointEntryId(_entryId));
        expect(conn.sqls.length, 2);
      },
    );

    test('returns a mid-transaction failure verbatim (rollback)', () async {
      final conn = _script([
        Result.ok([_entryRow(id: _entryId)]),
        const Result.err(
          AppError.transient('db.query_failed', 'Database query failed'),
        ),
      ]);
      final repo = PostgresLedgerRepository(conn);

      final result = await repo.appendEntries([
        _entry(id: _entryId),
        _entry(
          id: _entryId2,
          participant: '44444444-4444-4444-4444-444444444444',
        ),
      ]);

      expect(result, isA<Err<List<PointEntry>>>());
      expect((result as Err<List<PointEntry>>).error.kind, ErrorKind.transient);
    });

    test('maps a corrupt returned row to a transient error', () async {
      final conn = _script([
        Result.ok([_entryRow(amount: 0)..['amount'] = 'not-an-int']),
      ]);
      final repo = PostgresLedgerRepository(conn);

      final result = await repo.appendEntries([_entry()]);

      expect(result, isA<Err<List<PointEntry>>>());
      final error = (result as Err<List<PointEntry>>).error;
      expect(error.kind, ErrorKind.transient);
      expect(error.code, 'ledger.row_corrupt');
    });
  });

  group('PostgresLedgerRepository.listEntries', () {
    test('maps rows and requests occurred-at then id ordering', () async {
      final conn = _rows([
        _entryRow(id: _entryId, amount: 4),
        _entryRow(
          id: _entryId2,
          kind: 'correction',
          amount: -1,
          sourceRef: 'correction:x',
          occurredAt: '2026-07-11T13:00:00.000Z',
        ),
      ]);
      final repo = PostgresLedgerRepository(conn);

      final result = await repo.listEntries(_pId);

      expect(result, isA<Ok<List<PointEntry>>>());
      final entries = (result as Ok<List<PointEntry>>).value;
      expect(entries.map((e) => e.id.value), [_entryId, _entryId2]);
      expect(entries.last.kind, EntryKind.correction);
      expect(entries.last.amount, -1);
      expect(conn.sqls.single, contains('ORDER BY occurred_at ASC, id ASC'));
      expect(conn.parameters.single, {'participant_id': _participantId});
    });

    test('passes a transient query failure through verbatim', () async {
      final repo = PostgresLedgerRepository(_fails());

      final result = await repo.listEntries(_pId);

      expect(result, isA<Err<List<PointEntry>>>());
      expect((result as Err<List<PointEntry>>).error.kind, ErrorKind.transient);
    });

    test('maps a corrupt kind token to a transient error', () async {
      final repo = PostgresLedgerRepository(
        _rows([_entryRow()..['entry_kind'] = 'nonsense']),
      );

      final result = await repo.listEntries(_pId);

      final error = (result as Err<List<PointEntry>>).error;
      expect(error.kind, ErrorKind.transient);
      expect(error.code, 'ledger.row_corrupt');
    });
  });

  group('PostgresLedgerRepository.balanceFor', () {
    test(
      'projects the signed sum over the stream (== domain projection)',
      () async {
        final conn = _rows([
          _entryRow(id: _entryId, amount: 4),
          _entryRow(
            id: _entryId2,
            kind: 'correction',
            amount: -1,
            sourceRef: 'correction:x',
            occurredAt: '2026-07-11T13:00:00.000Z',
          ),
        ]);
        final repo = PostgresLedgerRepository(conn);

        final result = await repo.balanceFor(_pId);

        expect(result, isA<Ok<LedgerBalance>>());
        final balance = (result as Ok<LedgerBalance>).value;
        expect(balance.participantId, _pId);
        expect(balance.balance, 3); // 4 - 1
        expect(balance.entryCount, 2);
        // Reads via listEntries (one query), then projects with the domain.
        expect(conn.sqls.single, contains('FROM ledger.point_entries'));
      },
    );

    test('an empty stream projects a zero balance', () async {
      final repo = PostgresLedgerRepository(_rows(const []));

      final result = await repo.balanceFor(_pId);

      final balance = (result as Ok<LedgerBalance>).value;
      expect(balance.balance, 0);
      expect(balance.entryCount, 0);
    });

    test('propagates a transient stream-read failure', () async {
      final repo = PostgresLedgerRepository(_fails());

      final result = await repo.balanceFor(_pId);

      expect(result, isA<Err<LedgerBalance>>());
      expect((result as Err<LedgerBalance>).error.kind, ErrorKind.transient);
    });
  });

  group('PostgresParticipantReader.findParticipantById', () {
    test('returns the mapped participant and binds the id', () async {
      final conn = _rows([_participantRow()]);
      final repo = PostgresParticipantReader(conn);

      final result = await repo.findParticipantById(_pId);

      expect(result, isA<Ok<Participant?>>());
      final participant = (result as Ok<Participant?>).value!;
      expect(participant.id, _pId);
      expect(participant.userId, const UserId(_userId));
      expect(participant.status, ParticipantStatus.active);
      expect(conn.sqls.single, contains('FROM competition.participants'));
      expect(conn.sqls.single, contains('WHERE id = @id'));
      expect(conn.parameters.single, {'id': _participantId});
    });

    test('returns Ok(null) when no such participant exists', () async {
      final repo = PostgresParticipantReader(_rows(const []));

      final result = await repo.findParticipantById(_pId);

      expect(result, isA<Ok<Participant?>>());
      expect((result as Ok<Participant?>).value, isNull);
    });

    test('maps a corrupt row to a transient error', () async {
      final repo = PostgresParticipantReader(
        _rows([_participantRow()..['status'] = 'nonsense']),
      );

      final result = await repo.findParticipantById(_pId);

      final error = (result as Err<Participant?>).error;
      expect(error.kind, ErrorKind.transient);
      expect(error.code, 'ledger.row_corrupt');
    });

    test('passes a transient query failure through verbatim', () async {
      final repo = PostgresParticipantReader(_fails());

      final result = await repo.findParticipantById(_pId);

      expect(result, isA<Err<Participant?>>());
      expect((result as Err<Participant?>).error.kind, ErrorKind.transient);
    });
  });
}
