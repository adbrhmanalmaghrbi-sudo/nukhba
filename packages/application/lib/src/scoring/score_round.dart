import 'package:application/src/competition/ports/competition_repository.dart';
import 'package:application/src/identity/authorization.dart';
import 'package:application/src/prediction/ports/prediction_repository.dart';
import 'package:application/src/prediction/prediction_view.dart';
import 'package:application/src/scoring/ports/fixture_result_repository.dart';
import 'package:application/src/scoring/ports/score_repository.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// Use-case: score every prediction in a round (Application ADR, Section 2:
/// command intent `ScoreRound`).
///
/// This is the server-side heart of the Scoring phase (Axioms 2/5: points are
/// computed and written server-side only; the client never computes or submits
/// them). It:
/// 1. authorizes the caller as an **admin** (only the platform scores);
/// 2. loads the round and enforces the phase precondition — a round may be
///    scored only while it is [RoundStatus.locked] (never `open`: predictions
///    would still be mutable; never re-scored once `scored` unless idempotently
///    replayed — see below). This is the application's first line of defence;
///    the migration's constraint is the backstop (Axiom 6);
/// 3. interprets the round's **frozen** [RulesetSnapshot] as a [ScoringRuleset]
///    (reading the frozen rules is what makes a historical round reproducible —
///    Axiom 5);
/// 4. reads every participant's one prediction ([PredictionRepository.listByRound])
///    and the actual [FixtureResult]s for the round's fixtures
///    ([FixtureResultRepository]);
/// 5. runs the pure domain [Scoring.scoreRound] per prediction (total,
///    deterministic — same inputs, same score);
/// 6. persists all [RoundScore]s atomically and transitions the round
///    `locked → scored` under an optimistic-concurrency guard.
///
/// **Idempotent** (Application ADR, Section 2): the score persistence upserts
/// per `(round, participant)` and re-running scoring on an already-`scored`
/// round recomputes the same deterministic result and re-persists it without
/// creating duplicates. Because the guarded status transition only fires on the
/// `locked → scored` edge, a replay on an already-`scored` round re-writes the
/// (identical) scores and reports success without a spurious transition
/// conflict.
///
/// Never throws; returns a typed [Result] carrying the scored [RoundScore]s.
final class ScoreRound {
  /// Creates the use-case over its collaborators.
  const ScoreRound({
    required CompetitionRepository competitionRepository,
    required PredictionRepository predictionRepository,
    required FixtureResultRepository resultRepository,
    required ScoreRepository scoreRepository,
  }) : _competition = competitionRepository,
       _predictions = predictionRepository,
       _results = resultRepository,
       _scores = scoreRepository;

  final CompetitionRepository _competition;
  final PredictionRepository _predictions;
  final FixtureResultRepository _results;
  final ScoreRepository _scores;

  /// Scores round [roundId] on behalf of admin [principal].
  Future<Result<List<RoundScore>>> call({
    required AuthenticatedUser principal,
    required String roundId,
  }) async {
    final auth = Authorization.requireRole(principal, PlatformRole.admin);
    if (auth is Err<AuthenticatedUser>) {
      return Result.err(auth.error);
    }

    final roundIdResult = RoundId.tryParse(roundId);
    if (roundIdResult is Err<RoundId>) {
      return Result.err(roundIdResult.error);
    }
    final rId = (roundIdResult as Ok<RoundId>).value;

    final roundResult = await _competition.findRound(rId);
    if (roundResult is Err<Round>) {
      return Result.err(roundResult.error);
    }
    final round = (roundResult as Ok<Round>).value;

    // Precondition: score only a round that is locked or already scored (a
    // deterministic idempotent replay). An open round is refused — its
    // predictions are still mutable, so scoring it would corrupt the record.
    if (round.status == RoundStatus.open) {
      return Result.err(
        AppError.invariant(
          'scoring.round_not_locked',
          'A round can be scored only after it is locked '
              '(round is ${round.status.wireValue})',
        ),
      );
    }

    // Interpret the frozen ruleset. A corrupt/foreign snapshot is a typed
    // failure, never a silent zero score.
    final rulesetResult = ScoringRuleset.fromSnapshot(round.ruleset);
    if (rulesetResult is Err<ScoringRuleset>) {
      return Result.err(rulesetResult.error);
    }
    final ruleset = (rulesetResult as Ok<ScoringRuleset>).value;

    // The round's fixture composition — the exact set every prediction covers
    // and the set of results scoring needs.
    final fixturesResult = await _predictions.listRoundFixtures(rId);
    if (fixturesResult is Err<List<RoundFixture>>) {
      return Result.err(fixturesResult.error);
    }
    final roundFixtures = (fixturesResult as Ok<List<RoundFixture>>).value;
    if (roundFixtures.isEmpty) {
      return Result.err(
        const AppError.invariant(
          'scoring.round_has_no_fixtures',
          'A round with no fixtures cannot be scored',
        ),
      );
    }
    final fixtureRefs = <FixtureRef>[
      for (final link in roundFixtures) link.fixture,
    ];

    // Load the actual results and require one per linked fixture — scoring an
    // incomplete result set would silently corrupt the record (Axiom 5).
    final resultsResult = await _results.findByFixtures(fixtureRefs);
    if (resultsResult is Err<List<FixtureResult>>) {
      return Result.err(resultsResult.error);
    }
    final results = (resultsResult as Ok<List<FixtureResult>>).value;
    if (results.length != fixtureRefs.length) {
      return Result.err(
        const AppError.invariant(
          'scoring.results_incomplete',
          'Every fixture in the round must have a recorded result before '
              'the round can be scored',
        ),
      );
    }

    // Load every participant's prediction for the round.
    final predictionsResult = await _predictions.listByRound(rId);
    if (predictionsResult is Err<List<PredictionView>>) {
      return Result.err(predictionsResult.error);
    }
    final predictions = (predictionsResult as Ok<List<PredictionView>>).value;

    // Score each prediction with the pure domain service (deterministic).
    final roundScores = <RoundScore>[];
    for (final view in predictions) {
      final scored = Scoring.scoreRound(
        prediction: view.prediction,
        ruleset: ruleset,
        results: results,
      );
      if (scored is Err<RoundScore>) {
        return Result.err(scored.error);
      }
      roundScores.add((scored as Ok<RoundScore>).value);
    }

    // Persist all scores atomically (all-or-nothing; idempotent per participant).
    final saved = await _scores.saveRoundScores(roundScores);
    if (saved is Err<void>) {
      return Result.err(saved.error);
    }

    // Transition locked → scored under an optimistic-concurrency guard. When the
    // round is already scored (idempotent replay) there is no edge to fire: the
    // scores were re-persisted above, so report success without transitioning.
    if (round.status == RoundStatus.locked) {
      final transitioned = round.transitionTo(RoundStatus.scored);
      if (transitioned is Err<Round>) {
        return Result.err(transitioned.error);
      }
      final scoredRound = (transitioned as Ok<Round>).value;
      final statusSaved = await _competition.updateRoundStatus(
        scoredRound,
        RoundStatus.locked,
      );
      if (statusSaved is Err<void>) {
        return Result.err(statusSaved.error);
      }
    }

    return Result.ok(List<RoundScore>.unmodifiable(roundScores));
  }
}
