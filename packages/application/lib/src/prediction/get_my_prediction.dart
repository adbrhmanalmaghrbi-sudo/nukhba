import 'package:application/src/competition/ports/competition_repository.dart';
import 'package:application/src/identity/authorization.dart';
import 'package:application/src/prediction/ports/prediction_repository.dart';
import 'package:application/src/prediction/prediction_view.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// Query use-case: read the calling participant's own prediction for a round
/// (Application ADR, Section 2: query separated from command).
///
/// A participant may always read *their own* prediction, at any round status —
/// there is no leak in showing you what you submitted (Security ADR, Section 2:
/// self-read is safe). The principal is resolved to a participant server-side
/// from the verified token and the round's season, so a caller can never read
/// another user's prediction through this path.
///
/// Returns `Ok(null)` when the caller has joined but not yet predicted this
/// round — an expected, non-error "no prediction yet" state.
///
/// Never throws; returns a typed [Result].
final class GetMyPrediction {
  /// Creates the use-case over its collaborators.
  const GetMyPrediction({
    required PredictionRepository predictionRepository,
    required CompetitionRepository competitionRepository,
  }) : _predictions = predictionRepository,
       _competition = competitionRepository;

  final PredictionRepository _predictions;
  final CompetitionRepository _competition;

  /// Reads [principal]'s prediction for round [roundId].
  ///
  /// Returns a [PredictionView] (prediction + stored `submitted_at`) so the
  /// edge builds a faithful `PredictionDto`; `Ok(null)` when the caller has
  /// joined but not yet predicted, or is not a participant of the season.
  Future<Result<PredictionView?>> call({
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

    final participantResult = await _competition.findParticipant(
      round.seasonId,
      principal.userId,
    );
    if (participantResult is Err<Participant?>) {
      return Result.err(participantResult.error);
    }
    final participant = (participantResult as Ok<Participant?>).value;
    if (participant == null) {
      // Not a participant of this season: no prediction can exist for them, and
      // exposing others' data is out of scope for this query.
      return const Result.ok(null);
    }

    return _predictions.findByRoundAndParticipant(rId, participant.id);
  }
}
