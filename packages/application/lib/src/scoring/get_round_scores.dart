import 'package:application/src/competition/ports/competition_repository.dart';
import 'package:application/src/identity/authorization.dart';
import 'package:application/src/scoring/ports/score_repository.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// Query use-case: read every participant's computed score for a round — but
/// only **after the round is scored** (Application ADR, Section 2: query
/// separated from command).
///
/// The visibility gate mirrors the Prediction phase's discipline (Axiom 2, the
/// integrity boundary): scores are meaningful only once the round is
/// [RoundStatus.scored]; exposing them earlier would reveal partial/absent
/// results. A request for a not-yet-scored round is rejected
/// [ErrorKind.invariant] `scoring.round_not_scored` rather than returning an
/// empty list, so the client distinguishes "too early" from "nobody scored".
///
/// The caller must be a participant of the round's season (a member sees the
/// pool they compete in); a non-participant is rejected. Enforced here as the
/// business-invariant layer; the migration's RLS is the backstop (Axiom 6).
///
/// Never throws; returns a typed [Result].
final class GetRoundScores {
  /// Creates the use-case over its collaborators.
  const GetRoundScores({
    required CompetitionRepository competitionRepository,
    required ScoreRepository scoreRepository,
  }) : _competition = competitionRepository,
       _scores = scoreRepository;

  final CompetitionRepository _competition;
  final ScoreRepository _scores;

  /// Lists all round scores for the scored round [roundId], visible to
  /// [principal] as a participant of its season.
  Future<Result<List<RoundScore>>> call({
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

    // Visibility gate: scores are exposed only once the round is scored.
    if (round.status != RoundStatus.scored) {
      return Result.err(
        AppError.invariant(
          'scoring.round_not_scored',
          'Round scores become visible only after the round is scored '
              '(round is ${round.status.wireValue})',
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
          'scoring.not_a_participant',
          'Only a participant of the season may view its scores',
        ),
      );
    }

    return _scores.listByRound(rId);
  }
}
