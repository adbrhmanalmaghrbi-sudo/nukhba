import 'package:application/application.dart';
import 'package:contracts/contracts.dart';

/// Projects a [PredictionView] (a prediction aggregate plus the submission
/// instant the repository stamped) onto the versioned wire shape
/// [PredictionDto] (API ADR §4).
///
/// This mapping lives here, once, so both prediction read surfaces — the
/// single "my prediction" (`GET /rounds/{id}/predictions`) and the locked-round
/// list (`GET /rounds/{id}/predictions/all`) — shape a prediction identically.
///
/// Integrity boundary (Axioms 2/5): only the user's stored *intent* crosses the
/// wire — fixture ids and predicted goals, plus safe identity/structure facts.
/// No points, score, or competitive-record value is ever included; those are
/// produced server-side by the later Scoring phase and are never part of the
/// prediction read model. `submitted_at` is the exact instant the repository
/// stamped (carried on the view), never fabricated at the edge; the scores echo
/// the stored list order the aggregate preserves.
Map<String, Object?> predictionViewToJson(PredictionView view) {
  final prediction = view.prediction;
  return PredictionDto(
    id: prediction.id.value,
    participantId: prediction.participantId.value,
    roundId: prediction.roundId.value,
    submittedAt: view.submittedAt.toIso8601String(),
    fixtureScores: [
      for (final score in prediction.scores)
        FixtureScoreDto(
          fixtureId: score.fixture.value,
          homeGoals: score.homeGoals,
          awayGoals: score.awayGoals,
        ),
    ],
  ).toJson();
}
