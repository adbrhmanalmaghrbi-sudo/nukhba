import 'package:domain/src/competition/participant_id.dart';
import 'package:domain/src/competition/round_id.dart';
import 'package:domain/src/competition/round_status.dart';
import 'package:domain/src/prediction/fixture_score_prediction.dart';
import 'package:domain/src/prediction/prediction_id.dart';
import 'package:shared/shared.dart';

/// The `Prediction` aggregate root — a single participant's forecast for a
/// single round.
///
/// Deliberately a **separate aggregate** from Competition (Database ADR,
/// Section 1 & 2.1): predictions are the platform's highest-volume write, so
/// they must never contend on the Competition aggregate. A [Prediction] names
/// the round and the participant it belongs to **by id only** ([roundId],
/// [participantId]) — it never embeds the Round or Participant entity, and it
/// carries **no** group reference (Axiom 4: "predict once, rank everywhere" —
/// the single prediction is reused across every ranking context, including
/// group leaderboards, so it must not bind to any one group).
///
/// The forecast itself is one [FixtureScorePrediction] per fixture in the round,
/// each behind the football seam (Axiom 3). Points are **never** computed or
/// stored here: turning a prediction plus a `FixtureResult` into `PointEntry`s
/// is the server-only Scoring phase (Axioms 2/5 integrity boundary — the client
/// submits intent, the backend owns the competitive record).
///
/// Invariants encoded as types / enforced at construction:
/// * Exactly **one** prediction per (participant, round) — this identity is the
///   aggregate's natural key; the "one per round" rule is enforced physically by
///   the unique constraint in the migration (Axiom 6, the backstop).
/// * A prediction may only be **submitted or amended while its round is
///   [RoundStatus.open]** — once the round leaves `open` (locked/scored) the
///   forecast is frozen (Axiom 6: application enforces "no submit after lock",
///   DB check is the last line).
/// * At least one fixture score, with **no duplicate fixtures** within the
///   forecast.
///
/// Pure and immutable; a change produces a new instance via [amend].
final class Prediction {
  const Prediction._({
    required this.id,
    required this.roundId,
    required this.participantId,
    required this.scores,
  });

  /// Rehydrates a prediction from already-trusted stored fields.
  ///
  /// Used by infrastructure adapters mapping a persisted row (plus its fixture
  /// score children) back into the domain. The stored values were validated by
  /// [submit]/[amend] (and DB constraints, Axiom 6) before they were written, so
  /// this constructor performs no re-validation.
  const Prediction.fromStored({
    required this.id,
    required this.roundId,
    required this.participantId,
    required this.scores,
  });

  /// Creates a brand-new prediction for [participantId] in [roundId].
  ///
  /// Fails with an [AppError] when:
  /// * the round is not [RoundStatus.open] — submitting after lock is an
  ///   invariant violation (Axiom 6);
  /// * [scores] is empty, or contains two entries for the same fixture.
  ///
  /// The caller supplies the server-minted [id] (the client never mints ids —
  /// Axioms 2/5). Kept total: no exception escapes into the command path.
  static Result<Prediction> submit({
    required PredictionId id,
    required RoundId roundId,
    required ParticipantId participantId,
    required RoundStatus roundStatus,
    required List<FixtureScorePrediction> scores,
  }) {
    if (!roundStatus.isOpen) {
      return const Result.err(
        AppError.invariant(
          'prediction.round_not_open',
          'Predictions can only be submitted while the round is open',
        ),
      );
    }
    final validationError = _validateScores(scores);
    if (validationError != null) {
      return Result.err(validationError);
    }
    return Result.ok(
      Prediction._(
        id: id,
        roundId: roundId,
        participantId: participantId,
        scores: List<FixtureScorePrediction>.unmodifiable(scores),
      ),
    );
  }

  /// Produces an amended copy of this prediction carrying [scores].
  ///
  /// Identity ([id], [roundId], [participantId]) is preserved — an amendment is
  /// the same prediction with a revised forecast (Axiom 4: one prediction per
  /// round, updated in place, never a second row). Fails when the round is no
  /// longer [RoundStatus.open], or when [scores] is empty / contains duplicate
  /// fixtures.
  Result<Prediction> amend({
    required RoundStatus roundStatus,
    required List<FixtureScorePrediction> scores,
  }) {
    if (!roundStatus.isOpen) {
      return const Result.err(
        AppError.invariant(
          'prediction.round_not_open',
          'Predictions can only be amended while the round is open',
        ),
      );
    }
    final validationError = _validateScores(scores);
    if (validationError != null) {
      return Result.err(validationError);
    }
    return Result.ok(
      Prediction._(
        id: id,
        roundId: roundId,
        participantId: participantId,
        scores: List<FixtureScorePrediction>.unmodifiable(scores),
      ),
    );
  }

  static AppError? _validateScores(List<FixtureScorePrediction> scores) {
    if (scores.isEmpty) {
      return const AppError.validation(
        'prediction.no_scores',
        'A prediction must contain at least one fixture score',
      );
    }
    final seen = <String>{};
    for (final score in scores) {
      if (!seen.add(score.fixture.value)) {
        return const AppError.validation(
          'prediction.duplicate_fixture',
          'A prediction must contain at most one score per fixture',
        );
      }
    }
    return null;
  }

  /// The server-minted identity of this prediction.
  final PredictionId id;

  /// The round this prediction belongs to (by id — never the Round entity).
  final RoundId roundId;

  /// The participant who made this prediction (by id — never the Participant
  /// entity). Combined with [roundId] this is the aggregate's natural key.
  final ParticipantId participantId;

  /// The forecast: one [FixtureScorePrediction] per fixture, at least one, with
  /// no duplicate fixtures. Always an unmodifiable list.
  final List<FixtureScorePrediction> scores;

  @override
  bool operator ==(Object other) =>
      other is Prediction &&
      other.id == id &&
      other.roundId == roundId &&
      other.participantId == participantId &&
      _scoresEqual(other.scores, scores);

  @override
  int get hashCode =>
      Object.hash(id, roundId, participantId, Object.hashAll(scores));

  @override
  String toString() =>
      'Prediction(id: ${id.value}, round: ${roundId.value}, '
      'participant: ${participantId.value}, fixtures: ${scores.length})';

  static bool _scoresEqual(
    List<FixtureScorePrediction> a,
    List<FixtureScorePrediction> b,
  ) {
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }
}
