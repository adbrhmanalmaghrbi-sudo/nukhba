import 'package:domain/src/competition/fixture_ref.dart';
import 'package:domain/src/prediction/fixture_score_prediction.dart';
import 'package:domain/src/prediction/prediction.dart';
import 'package:domain/src/scoring/fixture_result.dart';
import 'package:domain/src/scoring/fixture_score_result.dart';
import 'package:domain/src/scoring/round_score.dart';
import 'package:domain/src/scoring/scoring_ruleset.dart';
import 'package:shared/shared.dart';

/// The pure Scoring domain service: turn one [Prediction] plus the actual
/// [FixtureResult]s into a [RoundScore], under the round's frozen
/// [ScoringRuleset] (Axioms 2/5: computed server-side only; the client never
/// computes or submits points).
///
/// This is framework-free, total (returns [Result], never throws), and
/// deterministic — the same inputs always yield the same score, which is what
/// makes scoring reproducible and re-runnable (idempotency at the use-case level
/// builds on this determinism). It does not persist anything; persistence and
/// the append-only `PointEntry` record are the Ledger phase (Axiom 5).
///
/// Grading per fixture (most-specific first, so an exact match is never also
/// counted as a mere correct outcome):
/// 1. exact scoreline (home & away both match) → [ScoringRuleset.exactScorelinePoints];
/// 2. otherwise correct outcome (same home-win/draw/away-win) →
///    [ScoringRuleset.correctOutcomePoints];
/// 3. otherwise incorrect → [ScoringRuleset.incorrectPoints].
abstract final class Scoring {
  /// Scores [prediction] against [results] under [ruleset].
  ///
  /// [results] must contain exactly one [FixtureResult] for every fixture the
  /// prediction covers (no missing, no extra, no duplicates). Any mismatch is an
  /// [ErrorKind.invariant] failure — scoring a round with an incomplete or
  /// inconsistent result set would silently corrupt the competitive record
  /// (Axiom 5), so it is refused rather than partially computed. The per-fixture
  /// breakdown preserves the prediction's fixture order (Axiom 4: the one
  /// forecast, graded in place).
  static Result<RoundScore> scoreRound({
    required Prediction prediction,
    required ScoringRuleset ruleset,
    required List<FixtureResult> results,
  }) {
    final resultsByFixture = <String, FixtureResult>{};
    for (final result in results) {
      final key = result.fixture.value;
      if (resultsByFixture.containsKey(key)) {
        return const Result.err(
          AppError.invariant(
            'scoring.duplicate_result',
            'The result set contains more than one result for a fixture',
          ),
        );
      }
      resultsByFixture[key] = result;
    }

    if (resultsByFixture.length != prediction.scores.length) {
      return const Result.err(
        AppError.invariant(
          'scoring.result_count_mismatch',
          'The result set must cover exactly the fixtures the '
              'prediction predicted',
        ),
      );
    }

    final graded = <FixtureScoreResult>[];
    for (final scorePrediction in prediction.scores) {
      final result = resultsByFixture[scorePrediction.fixture.value];
      if (result == null) {
        return Result.err(
          AppError.invariant(
            'scoring.result_missing_for_fixture',
            'No actual result supplied for fixture '
                '${scorePrediction.fixture.value}',
          ),
        );
      }
      graded.add(_gradeFixture(scorePrediction, result, ruleset));
    }

    return RoundScore.fromGraded(
      roundId: prediction.roundId,
      participantId: prediction.participantId,
      rulesetVersion: ruleset.rulesetVersion,
      fixtureResults: graded,
    );
  }

  static FixtureScoreResult _gradeFixture(
    FixtureScorePrediction prediction,
    FixtureResult result,
    ScoringRuleset ruleset,
  ) {
    final FixtureRef fixture = prediction.fixture;

    if (prediction.homeGoals == result.homeGoals &&
        prediction.awayGoals == result.awayGoals) {
      return FixtureScoreResult(
        fixture: fixture,
        grade: FixtureScoreGrade.exactScoreline,
        points: ruleset.exactScorelinePoints,
      );
    }

    final predictedOutcome = MatchOutcome.fromGoals(
      prediction.homeGoals,
      prediction.awayGoals,
    );
    if (predictedOutcome == result.outcome) {
      return FixtureScoreResult(
        fixture: fixture,
        grade: FixtureScoreGrade.correctOutcome,
        points: ruleset.correctOutcomePoints,
      );
    }

    return FixtureScoreResult(
      fixture: fixture,
      grade: FixtureScoreGrade.incorrect,
      points: ruleset.incorrectPoints,
    );
  }
}
