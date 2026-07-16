import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

const _round = '33333333-3333-3333-3333-333333333333';
const _participant = '44444444-4444-4444-4444-444444444444';
const _fixtureA = '11111111-1111-1111-1111-111111111111';
const _fixtureB = '22222222-2222-2222-2222-222222222222';
const _fixtureC = '55555555-5555-5555-5555-555555555555';

FixtureScorePrediction _pred(String fixture, int home, int away) =>
    (FixtureScorePrediction.create(
              fixture: FixtureRef(fixture),
              homeGoals: home,
              awayGoals: away,
            )
            as Ok<FixtureScorePrediction>)
        .value;

FixtureResult _res(String fixture, int home, int away) =>
    (FixtureResult.create(
              fixture: FixtureRef(fixture),
              homeGoals: home,
              awayGoals: away,
            )
            as Ok<FixtureResult>)
        .value;

Prediction _prediction(List<FixtureScorePrediction> scores) =>
    (Prediction.submit(
              id: const PredictionId('66666666-6666-6666-6666-666666666666'),
              roundId: const RoundId(_round),
              participantId: const ParticipantId(_participant),
              roundStatus: RoundStatus.open,
              scores: scores,
            )
            as Ok<Prediction>)
        .value;

/// exact=5, outcome=2, incorrect=0 — the configured default.
final ScoringRuleset _ruleset =
    (ScoringRuleset.fromSnapshot(
              (RulesetSnapshot.create(
                        rulesetVersion: 1,
                        payload: const {
                          'format': 'football_scoreline',
                          'points': {
                            'exact_scoreline': 5,
                            'correct_outcome': 2,
                            'incorrect': 0,
                          },
                        },
                      )
                      as Ok<RulesetSnapshot>)
                  .value,
            )
            as Ok<ScoringRuleset>)
        .value;

void main() {
  group('Scoring.scoreRound grading', () {
    test('exact scoreline earns the exact award', () {
      final result = Scoring.scoreRound(
        prediction: _prediction([_pred(_fixtureA, 2, 1)]),
        ruleset: _ruleset,
        results: [_res(_fixtureA, 2, 1)],
      );
      final score = (result as Ok<RoundScore>).value;
      expect(
        score.fixtureResults.single.grade,
        FixtureScoreGrade.exactScoreline,
      );
      expect(score.fixtureResults.single.points, 5);
      expect(score.totalPoints, 5);
    });

    test('correct outcome but wrong scoreline earns the outcome award', () {
      final result = Scoring.scoreRound(
        prediction: _prediction([_pred(_fixtureA, 3, 0)]),
        ruleset: _ruleset,
        results: [_res(_fixtureA, 1, 0)],
      );
      final score = (result as Ok<RoundScore>).value;
      expect(
        score.fixtureResults.single.grade,
        FixtureScoreGrade.correctOutcome,
      );
      expect(score.fixtureResults.single.points, 2);
      expect(score.totalPoints, 2);
    });

    test(
      'a predicted draw with the wrong score is still a correct outcome',
      () {
        final result = Scoring.scoreRound(
          prediction: _prediction([_pred(_fixtureA, 1, 1)]),
          ruleset: _ruleset,
          results: [_res(_fixtureA, 2, 2)],
        );
        final score = (result as Ok<RoundScore>).value;
        expect(
          score.fixtureResults.single.grade,
          FixtureScoreGrade.correctOutcome,
        );
        expect(score.totalPoints, 2);
      },
    );

    test('wrong outcome earns the incorrect award', () {
      final result = Scoring.scoreRound(
        prediction: _prediction([_pred(_fixtureA, 2, 0)]),
        ruleset: _ruleset,
        results: [_res(_fixtureA, 0, 3)],
      );
      final score = (result as Ok<RoundScore>).value;
      expect(score.fixtureResults.single.grade, FixtureScoreGrade.incorrect);
      expect(score.fixtureResults.single.points, 0);
      expect(score.totalPoints, 0);
    });

    test('sums points across many fixtures, preserving prediction order', () {
      final result = Scoring.scoreRound(
        prediction: _prediction([
          _pred(_fixtureA, 2, 1), // exact -> 5
          _pred(_fixtureB, 3, 0), // outcome only -> 2
          _pred(_fixtureC, 1, 0), // wrong -> 0
        ]),
        ruleset: _ruleset,
        results: [
          _res(_fixtureA, 2, 1),
          _res(_fixtureB, 1, 0),
          _res(_fixtureC, 0, 2),
        ],
      );
      final score = (result as Ok<RoundScore>).value;
      expect(score.totalPoints, 7);
      expect(score.fixtureResults.map((r) => r.fixture.value).toList(), [
        _fixtureA,
        _fixtureB,
        _fixtureC,
      ]);
      expect(score.fixtureResults.map((r) => r.grade).toList(), [
        FixtureScoreGrade.exactScoreline,
        FixtureScoreGrade.correctOutcome,
        FixtureScoreGrade.incorrect,
      ]);
    });

    test('carries the ruleset version and the prediction identity', () {
      final result = Scoring.scoreRound(
        prediction: _prediction([_pred(_fixtureA, 0, 0)]),
        ruleset: _ruleset,
        results: [_res(_fixtureA, 0, 0)],
      );
      final score = (result as Ok<RoundScore>).value;
      expect(score.rulesetVersion, 1);
      expect(score.roundId, const RoundId(_round));
      expect(score.participantId, const ParticipantId(_participant));
    });

    test('is deterministic — identical inputs yield an equal RoundScore', () {
      RoundScore run() =>
          (Scoring.scoreRound(
                    prediction: _prediction([
                      _pred(_fixtureA, 2, 1),
                      _pred(_fixtureB, 0, 0),
                    ]),
                    ruleset: _ruleset,
                    results: [_res(_fixtureA, 2, 1), _res(_fixtureB, 1, 1)],
                  )
                  as Ok<RoundScore>)
              .value;
      expect(run(), run());
      expect(run().hashCode, run().hashCode);
    });
  });

  group('Scoring.scoreRound result-set integrity (Axiom 5)', () {
    test('rejects a missing result for a predicted fixture', () {
      final result = Scoring.scoreRound(
        prediction: _prediction([
          _pred(_fixtureA, 1, 0),
          _pred(_fixtureB, 2, 2),
        ]),
        ruleset: _ruleset,
        results: [_res(_fixtureA, 1, 0)],
      );
      final error = (result as Err<RoundScore>).error;
      expect(error.kind, ErrorKind.invariant);
      expect(error.code, 'scoring.result_count_mismatch');
    });

    test('rejects extra results not covered by the prediction', () {
      final result = Scoring.scoreRound(
        prediction: _prediction([_pred(_fixtureA, 1, 0)]),
        ruleset: _ruleset,
        results: [_res(_fixtureA, 1, 0), _res(_fixtureB, 2, 2)],
      );
      final error = (result as Err<RoundScore>).error;
      expect(error.kind, ErrorKind.invariant);
      expect(error.code, 'scoring.result_count_mismatch');
    });

    test('rejects a duplicated result for the same fixture', () {
      final result = Scoring.scoreRound(
        prediction: _prediction([
          _pred(_fixtureA, 1, 0),
          _pred(_fixtureB, 2, 2),
        ]),
        ruleset: _ruleset,
        results: [_res(_fixtureA, 1, 0), _res(_fixtureA, 1, 0)],
      );
      final error = (result as Err<RoundScore>).error;
      expect(error.kind, ErrorKind.invariant);
      expect(error.code, 'scoring.duplicate_result');
    });

    test('rejects a same-count result set that covers a different fixture', () {
      final result = Scoring.scoreRound(
        prediction: _prediction([_pred(_fixtureA, 1, 0)]),
        ruleset: _ruleset,
        results: [_res(_fixtureB, 1, 0)],
      );
      final error = (result as Err<RoundScore>).error;
      expect(error.kind, ErrorKind.invariant);
      expect(error.code, 'scoring.result_missing_for_fixture');
    });
  });
}
