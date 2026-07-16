import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:infrastructure/src/db/postgres_connection.dart';
import 'package:infrastructure/src/prediction/postgres_prediction_repository.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

/// Hermetic unit tests for [PostgresPredictionRepository].
///
/// These do NOT require a live database. They substitute a fake
/// [PostgresConnection] that replies to each successive `query` with the next
/// scripted [Result], so we can drive every *pure* branch the adapter owns: the
/// join-row → aggregate mapping (parent + ordered children), the
/// "empty means not-yet-predicted" (`Ok(null)`) outcome, the multi-participant
/// grouping in `listByRound`, the amendment guard (`RETURNING` empty →
/// `prediction.not_found`), the write parameter-binding contract, the
/// row-corruption mapping, and the verbatim pass-through of a transient error.
///
/// The one branch that genuinely needs the driver — reclassifying a `postgres`
/// [ServerException] into a domain `invariant` conflict via the violated
/// constraint name (`prediction.already_submitted` etc.) and the "no write
/// after lock" trigger `check_violation` backstop — is deliberately NOT
/// exercised here: the driver's `ServerException` has no public constructor, so
/// that path can only be verified honestly against real Postgres (see the
/// DB-gated `postgres_prediction_repository_integration_test.dart`). Splitting
/// the two keeps the unit run fully hermetic.

const _predictionId = '11111111-1111-1111-1111-111111111111';
const _predictionId2 = '1a1a1a1a-1a1a-1a1a-1a1a-1a1a1a1a1a1a';
const _roundId = '22222222-2222-2222-2222-222222222222';
const _participantId = '33333333-3333-3333-3333-333333333333';
const _participantId2 = '3b3b3b3b-3b3b-3b3b-3b3b-3b3b3b3b3b3b';
const _fixtureA = '44444444-4444-4444-4444-444444444444';
const _fixtureB = '55555555-5555-5555-5555-555555555555';

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
ParticipantId get _pId =>
    (ParticipantId.tryParse(_participantId) as Ok<ParticipantId>).value;

FixtureScorePrediction _score(String fixture, int home, int away) =>
    FixtureScorePrediction.fromStored(
      fixture: FixtureRef(fixture),
      homeGoals: home,
      awayGoals: away,
    );

Prediction _prediction({
  String id = _predictionId,
  String participant = _participantId,
  required List<FixtureScorePrediction> scores,
}) => Prediction.fromStored(
  id: PredictionId(id),
  roundId: _rId,
  participantId: ParticipantId(participant),
  scores: scores,
);

Map<String, dynamic> _scoreRow({
  String predictionId = _predictionId,
  String participantId = _participantId,
  required String fixture,
  required int home,
  required int away,
  required int order,
  DateTime? submittedAt,
}) => {
  'prediction_id': predictionId,
  'round_id': _roundId,
  'participant_id': participantId,
  'submitted_at': submittedAt ?? DateTime.utc(2026, 8, 1, 12),
  'fixture_id': fixture,
  'home_goals': home,
  'away_goals': away,
  'display_order': order,
};

void main() {
  group('findByRoundAndParticipant', () {
    test(
      'maps parent + ordered child rows into the Prediction aggregate',
      () async {
        final repo = PostgresPredictionRepository(
          _rows([
            _scoreRow(fixture: _fixtureA, home: 2, away: 1, order: 0),
            _scoreRow(fixture: _fixtureB, home: 0, away: 0, order: 1),
          ]),
        );

        final view =
            (await repo.findByRoundAndParticipant(_rId, _pId)
                    as Ok<PredictionView?>)
                .value!;
        final prediction = view.prediction;
        expect(prediction.id.value, _predictionId);
        expect(prediction.roundId.value, _roundId);
        expect(prediction.participantId.value, _participantId);
        // The stored submission instant is surfaced on the view.
        expect(view.submittedAt, DateTime.utc(2026, 8, 1, 12));
        // Children rebuilt in stored (display_order) order — equality is
        // position-significant.
        expect(prediction.scores, [
          _score(_fixtureA, 2, 1),
          _score(_fixtureB, 0, 0),
        ]);
      },
    );

    test('an empty result is a successful Ok(null), not an error', () async {
      final conn = _rows(const []);
      final repo = PostgresPredictionRepository(conn);

      final result = await repo.findByRoundAndParticipant(_rId, _pId);

      // The submit use-case relies on this to decide insert-vs-amend.
      expect((result as Ok<PredictionView?>).value, isNull);
      // The lookup binds both keys, never concatenates them (Security ADR §2).
      expect(conn.parameters.first['round_id'], _roundId);
      expect(conn.parameters.first['participant_id'], _participantId);
      expect(conn.sqls.first, isNot(contains(_roundId)));
    });

    test(
      'a non-integer stored goal maps to a transient row_corrupt fault',
      () async {
        final repo = PostgresPredictionRepository(
          _rows([
            {
              ..._scoreRow(fixture: _fixtureA, home: 2, away: 1, order: 0),
              'home_goals': 'two',
            },
          ]),
        );

        final err =
            (await repo.findByRoundAndParticipant(_rId, _pId)
                    as Err<PredictionView?>)
                .error;
        // Schema drift / corruption is an infrastructure fault, not the caller's.
        expect(err.kind, ErrorKind.transient);
        expect(err.code, 'prediction.row_corrupt');
      },
    );

    test('a transient query error is propagated verbatim', () async {
      final repo = PostgresPredictionRepository(_fails());

      final err =
          (await repo.findByRoundAndParticipant(_rId, _pId)
                  as Err<PredictionView?>)
              .error;
      expect(err.kind, ErrorKind.transient);
      expect(err.code, 'db.query_failed');
    });
  });

  group('save (insert parent + children)', () {
    test('binds parent + every child by @named parameter, in order', () async {
      // Two successful writes: parent insert, then one child (single fixture).
      final conn = _script([const Result.ok([]), const Result.ok([])]);
      final repo = PostgresPredictionRepository(conn);
      final now = DateTime.utc(2026, 8, 1, 12, 30);

      final result = await repo.save(
        _prediction(scores: [_score(_fixtureA, 3, 2)]),
        now,
      );

      expect(result, isA<Ok<void>>());
      // Parent write.
      expect(conn.parameters[0]['id'], _predictionId);
      expect(conn.parameters[0]['round_id'], _roundId);
      expect(conn.parameters[0]['participant_id'], _participantId);
      expect(conn.parameters[0]['submitted_at'], now.toIso8601String());
      expect(conn.sqls[0], contains('@participant_id'));
      // Child write, display_order derived from list position.
      expect(conn.parameters[1]['prediction_id'], _predictionId);
      expect(conn.parameters[1]['fixture_id'], _fixtureA);
      expect(conn.parameters[1]['home_goals'], 3);
      expect(conn.parameters[1]['away_goals'], 2);
      expect(conn.parameters[1]['display_order'], 0);
    });

    test(
      'writes each child row with its list-position display_order',
      () async {
        final conn = _script([
          const Result.ok([]), // parent
          const Result.ok([]), // child 0
          const Result.ok([]), // child 1
        ]);
        final repo = PostgresPredictionRepository(conn);

        await repo.save(
          _prediction(
            scores: [_score(_fixtureA, 1, 0), _score(_fixtureB, 2, 2)],
          ),
          DateTime.utc(2026, 8, 1),
        );

        expect(conn.parameters[1]['fixture_id'], _fixtureA);
        expect(conn.parameters[1]['display_order'], 0);
        expect(conn.parameters[2]['fixture_id'], _fixtureB);
        expect(conn.parameters[2]['display_order'], 1);
      },
    );

    test(
      'a transient parent-insert fault is surfaced and children are skipped',
      () async {
        final conn = _fails();
        final repo = PostgresPredictionRepository(conn);

        final err =
            (await repo.save(
                      _prediction(scores: [_score(_fixtureA, 0, 0)]),
                      DateTime.utc(2026, 8, 1),
                    )
                    as Err<void>)
                .error;
        expect(err.kind, ErrorKind.transient);
        expect(err.code, 'db.query_failed');
        // Only the parent insert ran; the child insert must not be attempted.
        expect(conn.sqls.length, 1);
      },
    );
  });

  group('update (amend: guard + replace children)', () {
    test('replaces children after a matched parent update', () async {
      final conn = _script([
        Result.ok([
          {'id': _predictionId}, // RETURNING id — the guard matched
        ]),
        const Result.ok([]), // delete old children
        const Result.ok([]), // insert child 0
      ]);
      final repo = PostgresPredictionRepository(conn);
      final now = DateTime.utc(2026, 8, 2);

      final result = await repo.update(
        _prediction(scores: [_score(_fixtureB, 4, 1)]),
        now,
      );

      expect(result, isA<Ok<void>>());
      expect(conn.parameters[0]['submitted_at'], now.toIso8601String());
      expect(conn.sqls[0], contains('RETURNING id'));
      // Old children dropped, then the new forecast written.
      expect(conn.sqls[1], contains('DELETE'));
      expect(conn.parameters[1]['prediction_id'], _predictionId);
      expect(conn.parameters[2]['fixture_id'], _fixtureB);
      expect(conn.parameters[2]['display_order'], 0);
    });

    test('zero rows updated is a prediction.not_found invariant', () async {
      final repo = PostgresPredictionRepository(_rows(const []));

      final err =
          (await repo.update(
                    _prediction(scores: [_score(_fixtureA, 0, 0)]),
                    DateTime.utc(2026, 8, 2),
                  )
                  as Err<void>)
              .error;
      // The prediction vanished between the use-case's read and this write.
      expect(err.kind, ErrorKind.invariant);
      expect(err.code, 'prediction.not_found');
    });

    test('a transient update fault is propagated', () async {
      final repo = PostgresPredictionRepository(_fails());

      final err =
          (await repo.update(
                    _prediction(scores: [_score(_fixtureA, 0, 0)]),
                    DateTime.utc(2026, 8, 2),
                  )
                  as Err<void>)
              .error;
      expect(err.kind, ErrorKind.transient);
      expect(err.code, 'db.query_failed');
    });
  });

  group('listByRound', () {
    test(
      'groups a flat join into one Prediction per participant, in order',
      () async {
        final repo = PostgresPredictionRepository(
          _rows([
            // Prediction 1 (participant 1): two fixtures.
            _scoreRow(fixture: _fixtureA, home: 1, away: 0, order: 0),
            _scoreRow(fixture: _fixtureB, home: 2, away: 2, order: 1),
            // Prediction 2 (participant 2): two fixtures.
            _scoreRow(
              predictionId: _predictionId2,
              participantId: _participantId2,
              fixture: _fixtureA,
              home: 0,
              away: 0,
              order: 0,
            ),
            _scoreRow(
              predictionId: _predictionId2,
              participantId: _participantId2,
              fixture: _fixtureB,
              home: 3,
              away: 1,
              order: 1,
            ),
          ]),
        );

        final views =
            (await repo.listByRound(_rId) as Ok<List<PredictionView>>).value;
        expect(views.length, 2);
        expect(views[0].prediction.id.value, _predictionId);
        expect(views[0].prediction.participantId.value, _participantId);
        expect(views[0].prediction.scores.length, 2);
        expect(views[0].submittedAt, DateTime.utc(2026, 8, 1, 12));
        expect(views[1].prediction.id.value, _predictionId2);
        expect(views[1].prediction.participantId.value, _participantId2);
        expect(views[1].prediction.scores, [
          _score(_fixtureA, 0, 0),
          _score(_fixtureB, 3, 1),
        ]);
      },
    );

    test('an empty round yields an empty list, not an error', () async {
      final repo = PostgresPredictionRepository(_rows(const []));

      final views =
          (await repo.listByRound(_rId) as Ok<List<PredictionView>>).value;
      expect(views, isEmpty);
    });

    test('a transient query error is propagated', () async {
      final repo = PostgresPredictionRepository(_fails());

      final err =
          (await repo.listByRound(_rId) as Err<List<PredictionView>>).error;
      expect(err.kind, ErrorKind.transient);
      expect(err.code, 'db.query_failed');
    });
  });

  group('listRoundFixtures (read-only projection of competition link)', () {
    test('maps rows into ordered RoundFixture links', () async {
      final conn = _rows([
        {'round_id': _roundId, 'fixture_id': _fixtureA, 'display_order': 0},
        {'round_id': _roundId, 'fixture_id': _fixtureB, 'display_order': 1},
      ]);
      final repo = PostgresPredictionRepository(conn);

      final links =
          (await repo.listRoundFixtures(_rId) as Ok<List<RoundFixture>>).value;
      expect(links.length, 2);
      expect(links[0].fixture.value, _fixtureA);
      expect(links[0].displayOrder, 0);
      expect(links[1].fixture.value, _fixtureB);
      // Reads the Competition-owned link table, bound by round id.
      expect(conn.sqls.first, contains('competition.round_fixtures'));
      expect(conn.parameters.first['round_id'], _roundId);
    });

    test(
      'an empty round yields an empty list (submission policy is elsewhere)',
      () async {
        final repo = PostgresPredictionRepository(_rows(const []));

        final links =
            (await repo.listRoundFixtures(_rId) as Ok<List<RoundFixture>>)
                .value;
        expect(links, isEmpty);
      },
    );

    test('a non-integer display_order maps to row_corrupt', () async {
      final repo = PostgresPredictionRepository(
        _rows([
          {'round_id': _roundId, 'fixture_id': _fixtureA, 'display_order': 'x'},
        ]),
      );

      final err =
          (await repo.listRoundFixtures(_rId) as Err<List<RoundFixture>>).error;
      expect(err.kind, ErrorKind.transient);
      expect(err.code, 'prediction.row_corrupt');
    });
  });
}
