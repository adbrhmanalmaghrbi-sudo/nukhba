import 'package:application/src/competition/ports/competition_repository.dart';
import 'package:application/src/identity/authorization.dart';
import 'package:application/src/prediction/ports/prediction_repository.dart';
import 'package:application/src/prediction/prediction_view.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// Query use-case: list every participant's prediction for a round — but only
/// **after the round is locked** (Application ADR, Section 2: query separated
/// from command).
///
/// This is the visibility gate that protects fair play (Axiom 2, the integrity
/// boundary): while a round is [RoundStatus.open] a participant's forecast is
/// private, because revealing others' predictions before the deadline would let
/// a caller copy them. Once the round leaves `open` (locked/scored) every
/// prediction is frozen and may be revealed for comparison and, later, scoring.
///
/// Enforced here as the second (business-invariant) authorization layer; the
/// migration's RLS is the backstop (Axiom 6). A request for an open round is
/// rejected [ErrorKind.authorization] `prediction.round_not_locked` rather than
/// silently returning an empty list, so the client can distinguish "too early"
/// from "nobody predicted".
///
/// The caller must be a participant of the round's season (a member sees the
/// pool they compete in); a non-participant is rejected.
///
/// Never throws; returns a typed [Result].
final class ListRoundPredictions {
  /// Creates the use-case over its collaborators.
  const ListRoundPredictions({
    required PredictionRepository predictionRepository,
    required CompetitionRepository competitionRepository,
  }) : _predictions = predictionRepository,
       _competition = competitionRepository;

  final PredictionRepository _predictions;
  final CompetitionRepository _competition;

  /// Lists all predictions for the locked round [roundId], visible to
  /// [principal] as a participant of its season.
  ///
  /// Each entry is a [PredictionView] (prediction + stored `submitted_at`), so
  /// the edge builds a faithful `PredictionDto` per prediction.
  Future<Result<List<PredictionView>>> call({
    required AuthenticatedUser principal,
    required String roundId,
  }) async {
    final auth = Authorization.requireRole(principal, PlatformRole.user);
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

    // Visibility gate: an open round's predictions stay private.
    if (round.status.isOpen) {
      return Result.err(
        const AppError.authorization(
          'prediction.round_not_locked',
          'Predictions become visible only after the round is locked',
        ),
      );
    }

    // Membership: only a participant of the season sees the competing pool.
    final participantResult = await _competition.findParticipant(
      round.seasonId,
      principal.userId,
    );
    if (participantResult is Err<Participant?>) {
      return Result.err(participantResult.error);
    }
    final participant = (participantResult as Ok<Participant?>).value;
    if (participant == null) {
      return Result.err(
        const AppError.authorization(
          'prediction.not_a_participant',
          'Only a participant of the season may view its predictions',
        ),
      );
    }

    return _predictions.listByRound(rId);
  }
}
