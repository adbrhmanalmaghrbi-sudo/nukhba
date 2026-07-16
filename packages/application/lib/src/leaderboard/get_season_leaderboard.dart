import 'package:application/src/competition/ports/competition_repository.dart';
import 'package:application/src/identity/authorization.dart';
import 'package:application/src/leaderboard/ports/leaderboard_repository.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// Query use-case: read a season's ranked standings — its **leaderboard**
/// (Application ADR §2: query separated from command; Leaderboards architecture
/// decision in project-context §2).
///
/// A leaderboard is a **read-side projection** over the ratified append-only
/// ledger (Axiom 5): the use-case reads the per-participant point totals for the
/// season via [LeaderboardRepository.seasonStandings] and ranks them with the
/// pure domain [SeasonLeaderboard.rank] (total order: points desc, joinedAt asc,
/// participant-id asc; standard-competition "1224" ranks). It never computes or
/// stores a points total of its own — the total is the SUM already produced by
/// the ledger, so the board can never disagree with the balance a participant
/// reads at `GET /participants/{id}/balance`.
///
/// **Visibility gate (Axiom 1, social-first, scoped to the competition):** the
/// leaderboard is visible to a **member of the season** — a caller who has
/// joined it (any [ParticipantStatus]; a withdrawn member keeps their
/// competitive record and may still see the board they were part of). This
/// mirrors `ListRoundPredictions`' season-membership gate. A non-member is
/// refused [ErrorKind.authorization] `leaderboard.not_a_participant` (so the
/// response is not a season-existence oracle beyond membership). There is **no**
/// admin gate — this is a read, not a points write (Axiom 2 governs writes).
/// The migration's RLS is the backstop (Axiom 6).
///
/// Never throws; returns a typed [Result].
final class GetSeasonLeaderboard {
  /// Creates the use-case over its collaborators.
  const GetSeasonLeaderboard({
    required LeaderboardRepository leaderboardRepository,
    required CompetitionRepository competitionRepository,
  }) : _leaderboard = leaderboardRepository,
       _competition = competitionRepository;

  final LeaderboardRepository _leaderboard;
  final CompetitionRepository _competition;

  /// Returns the ranked [SeasonLeaderboard] for [seasonId], visible to
  /// [principal] as a member of that season.
  Future<Result<SeasonLeaderboard>> call({
    required AuthenticatedUser principal,
    required String seasonId,
  }) async {
    // Layer 1: platform authority — at least a signed-in user.
    final auth = Authorization.requireRole(principal, PlatformRole.user);
    if (auth is Err<AuthenticatedUser>) {
      return Result.err(auth.error);
    }

    final seasonIdResult = SeasonId.tryParse(seasonId);
    if (seasonIdResult is Err<SeasonId>) {
      return Result.err(seasonIdResult.error);
    }
    final sId = (seasonIdResult as Ok<SeasonId>).value;

    // Layer 2 (visibility): only a member of the season sees its standings. A
    // non-member is refused identically whether or not the season exists (no
    // season-existence oracle beyond membership — Security ADR §2).
    final participantResult = await _competition.findParticipant(
      sId,
      principal.userId,
    );
    if (participantResult is Err<Participant?>) {
      return Result.err(participantResult.error);
    }
    final participant = (participantResult as Ok<Participant?>).value;
    if (participant == null) {
      return Result.err(
        const AppError.authorization(
          'leaderboard.not_a_participant',
          'Only a member of the season may view its leaderboard',
        ),
      );
    }

    // Read the per-participant projection (unranked) and rank it in the domain.
    final standingsResult = await _leaderboard.seasonStandings(sId);
    if (standingsResult is Err<List<LeaderboardEntry>>) {
      return Result.err(standingsResult.error);
    }
    final projections = (standingsResult as Ok<List<LeaderboardEntry>>).value;

    return SeasonLeaderboard.rank(seasonId: sId, projections: projections);
  }
}
