import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// One member's line on a **group** leaderboard: the ratified season
/// [LeaderboardEntry] (unranked projection) paired with the owning member's
/// [UserId].
///
/// The season standings projection (`leaderboard.season_standings`) is keyed by
/// `ParticipantId`, but a group's roster is a set of `UserId`s (decision #4: the
/// group leaderboard is the same projection filtered to the group's members).
/// This pairing carries the `userId` alongside the entry so the group board can
/// be rendered against the group's user-keyed roster without introducing a new
/// points source — the `entry` still comes verbatim from the ledger projection.
final class GroupStandingEntry {
  /// Pairs a season leaderboard [entry] with the [userId] it belongs to.
  const GroupStandingEntry({required this.userId, required this.entry});

  /// The member's platform user id (how the group roster maps to a participant).
  final UserId userId;

  /// The unranked season projection line for that member's participant.
  final LeaderboardEntry entry;

  @override
  bool operator ==(Object other) =>
      other is GroupStandingEntry &&
      other.userId == userId &&
      other.entry == entry;

  @override
  int get hashCode => Object.hash(userId, entry);
}

/// Read port for a **group's** season standings — the season standings
/// projection filtered to a group's membership (Groups decision #4: NO new
/// points source, NO new ranking logic; only the participant-set filter is new).
///
/// Backed by `PostgresGroupRepository`, which intersects the ratified
/// `leaderboard.season_standings` VIEW (the append-only-ledger projection —
/// Axiom 5) with the group's `group_memberships` and the season's
/// `competition.participants`, so a member appears **only if** they are also a
/// season participant (reusing the existing season-membership semantics — no new
/// enrolment concept). The ordering + standard-competition ("1224") ranks are
/// applied by the pure domain `SeasonLeaderboard.rank` in the use-case, NOT here.
///
/// General contract (Application ADR, Section 2):
/// * MUST NOT throw — every outcome is a typed [Result].
/// * MUST map infrastructure failures to [ErrorKind.transient].
/// * MUST return one [GroupStandingEntry] per (group member ∩ season
///   participant); the list order is unspecified (the use-case ranks it). An
///   empty list is legitimate (no group member is a participant of the season).
abstract interface class GroupStandingsReader {
  /// Returns the unranked group standing entries for [groupId] within
  /// [seasonId] — each a season projection line paired with its member user id,
  /// restricted to users who are both members of the group and participants of
  /// the season.
  Future<Result<List<GroupStandingEntry>>> groupSeasonStandings({
    required GroupId groupId,
    required SeasonId seasonId,
  });
}
