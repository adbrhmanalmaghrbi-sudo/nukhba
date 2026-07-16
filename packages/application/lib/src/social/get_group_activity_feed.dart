import 'package:application/src/group/ports/group_repository.dart';
import 'package:application/src/identity/authorization.dart';
import 'package:application/src/social/activity_event.dart';
import 'package:application/src/social/ports/activity_feed_reader.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// Query use-case: read a group's activity feed (Application ADR §2: a query
/// intent `GetGroupActivityFeed`, separated from commands).
///
/// The feed is a **pure read projection** (decision #2: NO table) assembled by
/// [ActivityFeedReader] from existing ratified data — `group.group_memberships`
/// join timestamps, scored `competition.rounds` + `ledger` postings, and
/// `leaderboard.season_standings` rank deltas. This use-case adds only the
/// authority + visibility gate and the request-limit clamp.
///
/// **Member-only visibility gate (decision #3, mirror of `ListGroupMembers`):**
/// only a member of the group may read its feed. A non-member is refused
/// [ErrorKind.authorization] `group.not_a_member`, identically whether or not
/// the group exists — no existence oracle. There is no admin/owner gate — every
/// member sees their circle's activity (Axiom 1, social-first).
///
/// The principal's membership is resolved from the verified token, never the
/// body (Security ADR §2). Events come back newest-first (occurredAt
/// descending); an empty list is legitimate (a fresh group).
///
/// **Tier-3 (decision #4):** this is a Social read; a failure is confined to
/// this use-case and never blocks a Tier-1 core operation.
///
/// Never throws; returns a typed [Result].
final class GetGroupActivityFeed {
  /// Creates the use-case over its collaborators.
  const GetGroupActivityFeed({
    required ActivityFeedReader feed,
    required GroupRepository groups,
  }) : _feed = feed,
       _groups = groups;

  final ActivityFeedReader _feed;
  final GroupRepository _groups;

  /// The default number of events returned when a caller does not specify a
  /// [limit].
  static const int defaultLimit = 50;

  /// The hard upper bound on how many events a single read may return, so an
  /// untrusted [limit] can never ask for an unbounded scan (a Tier-3 read must
  /// stay cheap — decision #4).
  static const int maxLimit = 200;

  /// Reads the activity feed of group [groupId], visible to [principal] as a
  /// member. [limit] is clamped to `[1, maxLimit]`; a null or non-positive
  /// value falls back to [defaultLimit].
  Future<Result<List<ActivityEvent>>> call({
    required AuthenticatedUser principal,
    required String groupId,
    int? limit,
  }) async {
    // Layer 1: platform authority — any signed-in user.
    final auth = Authorization.requireRole(principal, PlatformRole.user);
    if (auth is Err<AuthenticatedUser>) {
      return Result.err(auth.error);
    }

    final gIdResult = GroupId.tryParse(groupId);
    if (gIdResult is Err<GroupId>) {
      return Result.err(gIdResult.error);
    }
    final gId = (gIdResult as Ok<GroupId>).value;

    // Layer 2 (visibility): the caller must be a member. A non-member is refused
    // identically whether or not the group exists (no existence oracle —
    // decision #3, mirror of `ListGroupMembers`).
    final membershipResult = await _groups.findMembership(
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
          'Only a member of the group may view its activity feed',
        ),
      );
    }

    // Clamp the untrusted limit: null/non-positive → default; above the hard
    // cap → cap. A read never triggers an unbounded projection scan.
    final effectiveLimit = _clampLimit(limit);

    // Assemble the projection. The membership gate above already proved
    // existence to this member, so this feed is theirs to see.
    return _feed.groupActivityFeed(groupId: gId, limit: effectiveLimit);
  }

  int _clampLimit(int? limit) {
    if (limit == null || limit <= 0) {
      return defaultLimit;
    }
    if (limit > maxLimit) {
      return maxLimit;
    }
    return limit;
  }
}
