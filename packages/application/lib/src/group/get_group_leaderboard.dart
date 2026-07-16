import 'package:application/src/group/group_leaderboard.dart';
import 'package:application/src/group/ports/group_repository.dart';
import 'package:application/src/group/ports/group_standings_reader.dart';
import 'package:application/src/identity/authorization.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// Query use-case: read a **group's** ranked standings for a season — the same
/// season leaderboard projection filtered to the group's membership (Groups
/// decision #4: NO new points source, NO new ranking logic; only the
/// participant-set filter is new).
///
/// **Member-only visibility gate (decision #3, mirror of `ListGroupMembers` and
/// the season-membership gate):** only a member of the group may read its
/// board. A non-member is refused [ErrorKind.authorization] `group.not_a_member`
/// identically whether or not the group exists (no existence oracle). There is
/// no admin gate — a group leaderboard is a read, not a points write (Axiom 2
/// governs writes).
///
/// Realization (Axiom 5 — a single protected truth for points): the use-case
/// reads the unranked per-member projection via
/// [GroupStandingsReader.groupSeasonStandings] (the ratified
/// `leaderboard.season_standings` VIEW intersected with the group's membership),
/// ranks the underlying [LeaderboardEntry]s with the pure domain
/// [SeasonLeaderboard.rank] (points desc, joinedAt asc, participant-id asc;
/// standard-competition "1224" ranks), then re-attaches each member's [UserId]
/// to its ranked entry (the group roster is user-keyed, the projection is
/// participant-keyed). It never computes a total or a rank of its own — those
/// come verbatim from the ledger projection and the domain ranking.
///
/// An empty board is legitimate (a group whose members are not participants of
/// the season, or a group with members who have never been credited).
///
/// Never throws; returns a typed [Result].
final class GetGroupLeaderboard {
  /// Creates the use-case over its collaborators.
  const GetGroupLeaderboard({
    required GroupRepository repository,
    required GroupStandingsReader standingsReader,
  }) : _repository = repository,
       _standingsReader = standingsReader;

  final GroupRepository _repository;
  final GroupStandingsReader _standingsReader;

  /// Returns the ranked [GroupLeaderboard] for [groupId] within [seasonId],
  /// visible to [principal] as a member of the group.
  Future<Result<GroupLeaderboard>> call({
    required AuthenticatedUser principal,
    required String groupId,
    required String seasonId,
  }) async {
    // Layer 1: platform authority — any signed-in user.
    final auth = Authorization.requireRole(principal, PlatformRole.user);
    if (auth is Err<AuthenticatedUser>) {
      return Result.err(auth.error);
    }

    final groupIdResult = GroupId.tryParse(groupId);
    if (groupIdResult is Err<GroupId>) {
      return Result.err(groupIdResult.error);
    }
    final gId = (groupIdResult as Ok<GroupId>).value;

    final seasonIdResult = SeasonId.tryParse(seasonId);
    if (seasonIdResult is Err<SeasonId>) {
      return Result.err(seasonIdResult.error);
    }
    final sId = (seasonIdResult as Ok<SeasonId>).value;

    // Layer 2 (visibility): the caller must be a member of the group. A
    // non-member is refused identically whether or not the group exists (no
    // existence oracle — decision #3).
    final membershipResult = await _repository.findMembership(
      gId,
      principal.userId,
    );
    if (membershipResult is Err<GroupMembership?>) {
      return Result.err(membershipResult.error);
    }
    final membership = (membershipResult as Ok<GroupMembership?>).value;
    if (membership == null) {
      return Result.err(
        const AppError.authorization(
          'group.not_a_member',
          'Only a member of the group may view its leaderboard',
        ),
      );
    }

    // Read the unranked group∩season projection (each: member userId + unranked
    // season entry). The reader restricts to users who are both group members
    // and season participants (reusing the season-membership semantics — no new
    // enrolment concept, decision #4).
    final standingsResult = await _standingsReader.groupSeasonStandings(
      groupId: gId,
      seasonId: sId,
    );
    if (standingsResult is Err<List<GroupStandingEntry>>) {
      return Result.err(standingsResult.error);
    }
    final unranked = (standingsResult as Ok<List<GroupStandingEntry>>).value;

    // Rank the underlying entries with the pure domain — the identical ranking
    // rule used for the season board, so a group board can never disagree with
    // it for the members it shows.
    final ranked = SeasonLeaderboard.rank(
      seasonId: sId,
      projections: [for (final s in unranked) s.entry],
    );
    if (ranked is Err<SeasonLeaderboard>) {
      return Result.err(ranked.error);
    }
    final board = (ranked as Ok<SeasonLeaderboard>).value;

    // Re-attach each member's userId to its ranked entry, keyed on the stable
    // participantId (the group roster is user-keyed; the domain board is
    // participant-keyed). The reader guarantees one entry per participant, so
    // this lookup is unambiguous.
    final userByParticipant = <String, UserId>{
      for (final s in unranked) s.entry.participantId.value: s.userId,
    };

    final result = <RankedGroupStanding>[];
    for (final entry in board.entries) {
      final userId = userByParticipant[entry.participantId.value];
      if (userId == null) {
        // The domain re-ordered the same set the reader produced; every ranked
        // participant must map back to a member userId. A gap would mean the
        // reader returned inconsistent rows — surface it as transient rather
        // than fabricate a mapping (a read path never lies about ownership).
        return Result.err(
          AppError.transient(
            'group.standings_inconsistent',
            'A ranked participant ${entry.participantId.value} could not be '
                'mapped back to a group member',
          ),
        );
      }
      result.add(RankedGroupStanding(userId: userId, entry: entry));
    }

    return Result.ok(
      GroupLeaderboard(
        groupId: gId,
        seasonId: sId,
        standings: List<RankedGroupStanding>.unmodifiable(result),
      ),
    );
  }
}
