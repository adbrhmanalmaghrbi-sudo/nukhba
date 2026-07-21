// ignore_for_file: prefer_const_constructors
import 'package:domain/domain.dart';
import 'package:infrastructure/src/db/postgres_connection.dart';
import 'package:infrastructure/src/scoring/postgres_fixture_result_repository.dart';
import 'package:infrastructure/src/scoring/postgres_score_repository.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

/// Hermetic unit tests for the Scoring infrastructure adapters
/// ([PostgresFixtureResultRepository] and [PostgresScoreRepository]).
///
/// These do NOT require a live database. They substitute a fake
/// [PostgresConnection] that replies to each successive `query` with the next
/// scripted [Result] (and models `runInTransaction` by running the action's
/// statements against the same fake), so we can drive every *pure* branch the
/// adapters own:
///   * `fixture_results` upsert parameter-binding, single-fixture read
///     (`Ok(null)` when absent), batch read (absent fixtures omitted), and the
///     row-corruption mapping;
///   * `round_scores` + `round_score_fixtures` atomic write (parent upsert +
///     child delete + ordered reinsert), the empty-batch no-op, the verbatim
///     pass-through of a mid-transaction failure, the multi-participant
///     grouping in `listByRound`, and its row-corruption mappings.
///
/// The one branch that genuinely needs the driver — reclassifying a `postgres`
/// [ServerException] into a domain `invariant` conflict via the SQLSTATE
/// `code`/`constraintName` (`scoring.result_integrity_violation`,
/// `scoring.round_not_found`, `scoring.not_a_participant`, …) — is deliberately
/// NOT exercised here: the driver's `ServerException` has no public
/// constructor, so that path can only be verified honestly against real
/// Postgres (see the DB-gated
/// `postgres_scoring_repositories_integration_test.dart`).

const _roundId = '22222222-2222-2222-2222-222222222222';
const _participantId = '33333333-3333-3333-3333-333333333333';
const _participantId2 = '3b3b3b3b-3b3b-3b3b-3b3b-3b3b3b3b3b3b';
const _fixtureA = '44444444-4444-4444-4444-444444444444';
const _fixtureB = '55555555-5555-5555-5555-555555555555';
const _fixtureC = '66666666-6666-6666-6666-666666666666';

/// A [PostgresConnection] test double that replays a scripted queue of
/// [Result]s (one per `query`) and records every SQL + parameter set it saw. It
/// never touches a real pool, so the whole test is hermetic.
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
    // Faithfully model the real transaction contract against the scripted
    // queue: the action's statements run against this same fake (so each
    // `query` consumes the next scripted response), an Ok commits and is
    // returned, and an Err "rolls back" — the outcome is returned verbatim, so
    // the adapter's SQLSTATE→invariant reclassification is preserved exactly as
    // it is in production. This lets the write tests script a mid-transaction
    // child-insert failure and assert the returned Err.
    return action(this);
  }

  @override
  Future<void> close() async {}
}

/// A connection that answers a single query with [rows].
_FakeConnection _rows(List<Map<String, dynamic>> rows) =>
    _FakeConnection([Result.ok(rows)]);

/// A connection that answers a sequence of queries with [responses].
_FakeConnection _script(List<Result<List<Map<String, dynamic>>>> responses) =>
    _FakeConnection(responses);

/// A connection whose every query fails transiently.
_FakeConnection _fails() => _FakeConnection([
  const Result.err(
    AppError.transient('db.query_failed', 'Database query failed'),
  ),
]);

RoundId get _rId => (RoundId.tryParse(_roundId) as Ok<RoundId>).value;

FixtureResult _result(String fixture, int home, int away) =>
    FixtureResult.fromStored(
      fixture: FixtureRef(fixture),
      homeGoals: home,
      awayGoals: away,
    );

FixtureScoreResult _graded(
  String fixture,
  FixtureScoreGrade grade,
  int points,
) => FixtureScoreResult(
  fixture: FixtureRef(fixture),
  grade: grade,
  points: points,
);

RoundScore _roundScore({
  String participant = _participantId,
  int rulesetVersion = 1,
  required List<FixtureScoreResult> fixtures,
}) {
  var total = 0;
  for (final f in fixtures) {
    total += f.points;
  }
  return RoundScore.fromStored(
    roundId: _rId,
    participantId: ParticipantId(participant),
    rulesetVersion: rulesetVersion,
    totalPoints: total,
    fixtureResults: fixtures,
  );
}

Map<String, dynamic> _resultRow(String fixture, int home, int away) => {
  'fixture_id': fixture,
  'home_goals': home,
  'away_goals': away,
};

Map<String, dynamic> _scoreJoinRow({
  String round = _roundId,
  String participant = _participantId,
  int rulesetVersion = 1,
  int totalPoints = 0,
  required String fixture,
  required String grade,
  required int points,
  required int displayOrder,
}) => {
  'round_id': round,
  'participant_id': participant,
  'ruleset_version': rulesetVersion,
  'total_points': totalPoints,
  'fixture_id': fixture,
  'grade': grade,
  'points': points,
  'display_order': displayOrder,
};

void main() {
  group('PostgresFixtureResultRepository', () {
    test('upsert binds fixture id, goals and UTC recorded_at', () async {
      final conn = _rows(const []);
      final repo = PostgresFixtureResultRepository(conn);
      final recordedAt = DateTime.utc(2026, 7, 11, 18, 30);

      final result = await repo.upsert(_result(_fixtureA, 2, 1), recordedAt);

      expect(result, isA<Ok<void>>());
      expect(conn.sqls.single, contains('INSERT INTO scoring.fixture_results'));
      expect(conn.sqls.single, contains('ON CONFLICT (fixture_id) DO UPDATE'));
      expect(conn.parameters.single, {
        'fixture_id': _fixtureA,
        'home_goals': 2,
        'away_goals': 1,
        'recorded_at': '2026-07-11T18:30:00.000Z',
      });
    });

    test('upsert normalises a non-UTC recorded_at to UTC ISO-8601', () async {
      final conn = _rows(const []);
      final repo = PostgresFixtureResultRepository(conn);
      // A local-zone instant: the adapter must stamp UTC for a stable audit.
      final local = DateTime.utc(2026, 7, 11, 18, 30).toLocal();

      await repo.upsert(_result(_fixtureA, 0, 0), local);

      expect(conn.parameters.single['recorded_at'], '2026-07-11T18:30:00.000Z');
    });

    test('upsert passes a transient failure through verbatim', () async {
      final repo = PostgresFixtureResultRepository(_fails());

      final result = await repo.upsert(
        _result(_fixtureA, 1, 0),
        DateTime.utc(2026),
      );

      expect(result, isA<Err<void>>());
      expect((result as Err<void>).error.kind, ErrorKind.transient);
    });

    test('findByFixture returns the mapped result', () async {
      final conn = _rows([_resultRow(_fixtureA, 3, 2)]);
      final repo = PostgresFixtureResultRepository(conn);

      final result = await repo.findByFixture(FixtureRef(_fixtureA));

      expect(result, isA<Ok<FixtureResult?>>());
      final value = (result as Ok<FixtureResult?>).value!;
      expect(value.fixture, FixtureRef(_fixtureA));
      expect(value.homeGoals, 3);
      expect(value.awayGoals, 2);
      expect(conn.parameters.single, {'fixture_id': _fixtureA});
    });

    test('findByFixture returns Ok(null) when no result is recorded', () async {
      final repo = PostgresFixtureResultRepository(_rows(const []));

      final result = await repo.findByFixture(FixtureRef(_fixtureA));

      expect(result, isA<Ok<FixtureResult?>>());
      expect((result as Ok<FixtureResult?>).value, isNull);
    });

    test('findByFixture maps a corrupt row to a transient error', () async {
      final repo = PostgresFixtureResultRepository(
        _rows([
          {'fixture_id': _fixtureA, 'home_goals': 'x', 'away_goals': 1},
        ]),
      );

      final result = await repo.findByFixture(FixtureRef(_fixtureA));

      expect(result, isA<Err<FixtureResult?>>());
      final error = (result as Err<FixtureResult?>).error;
      expect(error.kind, ErrorKind.transient);
      expect(error.code, 'scoring.row_corrupt');
    });

    test(
      'findByFixtures returns Ok([]) for an empty list without querying',
      () async {
        final conn = _rows(const []);
        final repo = PostgresFixtureResultRepository(conn);

        final result = await repo.findByFixtures(const []);

        expect(result, isA<Ok<List<FixtureResult>>>());
        expect((result as Ok<List<FixtureResult>>).value, isEmpty);
        expect(conn.sqls, isEmpty); // no round trip for an empty batch
      },
    );

    test(
      'findByFixtures binds the id list as a single array parameter',
      () async {
        final conn = _rows([
          _resultRow(_fixtureA, 1, 0),
          _resultRow(_fixtureB, 0, 0),
        ]);
        final repo = PostgresFixtureResultRepository(conn);

        final result = await repo.findByFixtures([
          FixtureRef(_fixtureA),
          FixtureRef(_fixtureB),
          FixtureRef(_fixtureC), // no row → simply absent from the result
        ]);

        expect(result, isA<Ok<List<FixtureResult>>>());
        final value = (result as Ok<List<FixtureResult>>).value;
        expect(
          value.length,
          2,
        ); // the gap is detected by count, never zero-filled
        expect(conn.sqls.single, contains('= ANY(@fixture_ids)'));
        expect(conn.parameters.single, {
          'fixture_ids': [_fixtureA, _fixtureB, _fixtureC],
        });
      },
    );
  });

  group('PostgresScoreRepository', () {
    test(
      'saveRoundScores is a no-op for an empty batch (no transaction)',
      () async {
        final conn = _rows(const []);
        final repo = PostgresScoreRepository(conn);

        final result = await repo.saveRoundScores(const []);

        expect(result, isA<Ok<void>>());
        expect(conn.sqls, isEmpty);
      },
    );

    test(
      'saveRoundScores writes parent upsert + child delete + ordered inserts',
      () async {
        // One participant, two fixtures: expect 1 upsert + 1 delete + 2 inserts.
        final conn = _script(const [
          Result.ok(<Map<String, dynamic>>[]), // upsert parent
          Result.ok(<Map<String, dynamic>>[]), // delete children
          Result.ok(<Map<String, dynamic>>[]), // insert fixture A
          Result.ok(<Map<String, dynamic>>[]), // insert fixture B
        ]);
        final repo = PostgresScoreRepository(conn);

        final result = await repo.saveRoundScores([
          _roundScore(
            fixtures: [
              _graded(_fixtureA, FixtureScoreGrade.exactScoreline, 5),
              _graded(_fixtureB, FixtureScoreGrade.correctOutcome, 2),
            ],
          ),
        ]);

        expect(result, isA<Ok<void>>());
        expect(conn.sqls.length, 4);
        expect(conn.sqls[0], contains('INSERT INTO scoring.round_scores'));
        expect(
          conn.sqls[0],
          contains('ON CONFLICT (round_id, participant_id)'),
        );
        expect(
          conn.sqls[1],
          contains('DELETE FROM scoring.round_score_fixtures'),
        );
        expect(
          conn.sqls[2],
          contains('INSERT INTO scoring.round_score_fixtures'),
        );
        // Parent carries the derived total (5 + 2).
        expect(conn.parameters[0]['total_points'], 7);
        expect(conn.parameters[0]['ruleset_version'], 1);
        // Children inserted in list (prediction) order with display_order 0,1.
        expect(conn.parameters[2]['fixture_id'], _fixtureA);
        expect(conn.parameters[2]['grade'], 'exact_scoreline');
        expect(conn.parameters[2]['points'], 5);
        expect(conn.parameters[2]['display_order'], 0);
        expect(conn.parameters[3]['fixture_id'], _fixtureB);
        expect(conn.parameters[3]['grade'], 'correct_outcome');
        expect(conn.parameters[3]['display_order'], 1);
      },
    );

    test(
      'saveRoundScores returns the mid-transaction failure verbatim',
      () async {
        // Parent upsert ok, then the child delete fails: the whole batch rolls
        // back (modelled by the fake returning the Err verbatim).
        final conn = _script(const [
          Result.ok(<Map<String, dynamic>>[]), // upsert parent
          Result.err(
            AppError.transient('db.query_failed', 'Database query failed'),
          ), // delete children fails
        ]);
        final repo = PostgresScoreRepository(conn);

        final result = await repo.saveRoundScores([
          _roundScore(
            fixtures: [_graded(_fixtureA, FixtureScoreGrade.incorrect, 0)],
          ),
        ]);

        expect(result, isA<Err<void>>());
        expect((result as Err<void>).error.kind, ErrorKind.transient);
      },
    );

    test('listByRound groups a flat join into per-participant scores', () async {
      // Two participants, ordered by participant id; each with two fixtures in
      // display_order. Participant _participantId (33..) sorts before
      // _participantId2 (3b..).
      final conn = _rows([
        _scoreJoinRow(
          participant: _participantId,
          totalPoints: 7,
          fixture: _fixtureA,
          grade: 'exact_scoreline',
          points: 5,
          displayOrder: 0,
        ),
        _scoreJoinRow(
          participant: _participantId,
          totalPoints: 7,
          fixture: _fixtureB,
          grade: 'correct_outcome',
          points: 2,
          displayOrder: 1,
        ),
        _scoreJoinRow(
          participant: _participantId2,
          totalPoints: 0,
          fixture: _fixtureA,
          grade: 'incorrect',
          points: 0,
          displayOrder: 0,
        ),
        _scoreJoinRow(
          participant: _participantId2,
          totalPoints: 0,
          fixture: _fixtureB,
          grade: 'incorrect',
          points: 0,
          displayOrder: 1,
        ),
      ]);
      final repo = PostgresScoreRepository(conn);

      final result = await repo.listByRound(_rId);

      expect(result, isA<Ok<List<RoundScore>>>());
      final scores = (result as Ok<List<RoundScore>>).value;
      expect(scores.length, 2);
      expect(scores[0].participantId, ParticipantId(_participantId));
      expect(scores[0].totalPoints, 7);
      expect(scores[0].fixtureResults.length, 2);
      expect(scores[0].fixtureResults[0].fixture, FixtureRef(_fixtureA));
      expect(
        scores[0].fixtureResults[0].grade,
        FixtureScoreGrade.exactScoreline,
      );
      expect(scores[0].fixtureResults[1].fixture, FixtureRef(_fixtureB));
      expect(scores[1].participantId, ParticipantId(_participantId2));
      expect(scores[1].totalPoints, 0);
      expect(conn.parameters.single, {'round_id': _roundId});
    });

    test('listByRound returns Ok([]) when the round is not scored', () async {
      final repo = PostgresScoreRepository(_rows(const []));

      final result = await repo.listByRound(_rId);

      expect(result, isA<Ok<List<RoundScore>>>());
      expect((result as Ok<List<RoundScore>>).value, isEmpty);
    });

    test(
      'listByRound maps a corrupt grade token to a transient error',
      () async {
        final repo = PostgresScoreRepository(
          _rows([
            _scoreJoinRow(
              fixture: _fixtureA,
              grade: 'nonsense_grade',
              points: 1,
              displayOrder: 0,
            ),
          ]),
        );

        final result = await repo.listByRound(_rId);

        expect(result, isA<Err<List<RoundScore>>>());
        final error = (result as Err<List<RoundScore>>).error;
        expect(error.kind, ErrorKind.transient);
        expect(error.code, 'scoring.row_corrupt');
      },
    );

    test(
      'listByRound passes a transient query failure through verbatim',
      () async {
        final repo = PostgresScoreRepository(_fails());

        final result = await repo.listByRound(_rId);

        expect(result, isA<Err<List<RoundScore>>>());
        expect(
          (result as Err<List<RoundScore>>).error.kind,
          ErrorKind.transient,
        );
      },
    );
  });
}
