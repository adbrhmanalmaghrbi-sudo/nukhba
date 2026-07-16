import 'package:application/src/group/ports/group_repository.dart';
import 'package:application/src/identity/authorization.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// A group together with its current member count — the read value returned by
/// [GetGroup].
///
/// The `member_count` is not carried on the `Group` aggregate itself (a group is
/// orthogonal to its membership rows — Groups decision #1/#2), so a member-gated
/// group read resolves the roster size alongside the group and pairs them here.
/// This keeps the route from making a second call and lets the mapper shape a
/// complete [Group] wire view (name/owner/invite/createdAt + memberCount) in one
/// place.
final class GroupWithMemberCount {
  /// Pairs a [group] with its [memberCount].
  const GroupWithMemberCount({required this.group, required this.memberCount});

  /// The group aggregate the caller is a member of.
  final Group group;

  /// How many members the group currently has (the owner is always counted, so
  /// this is at least 1 for an existing group).
  final int memberCount;

  @override
  bool operator ==(Object other) =>
      other is GroupWithMemberCount &&
      other.group == group &&
      other.memberCount == memberCount;

  @override
  int get hashCode => Object.hash(group, memberCount);

  @override
  String toString() =>
      'GroupWithMemberCount(group: ${group.id.value}, members: $memberCount)';
}

/// Query use-case: read a single [Group] (Application ADR §2: a query intent
/// `GetGroup`, separated from commands).
///
/// **Member-only visibility gate (Groups decision #3, mirror of
/// [ListGroupMembers] and the season-membership gate):** only a member of the
/// group may read it. A caller who is not a member is refused
/// [ErrorKind.authorization] `group.not_a_member`, identically whether or not
/// the group exists — so the response is never a group-existence oracle for a
/// non-member (private-by-default, invite-only discovery). There is no
/// admin/owner gate — every member may read their own circle (Axiom 1). The
/// invite code IS returned to a member (it is a capability the member already
/// holds; the mapper only ever shapes it for a member-visible payload).
///
/// The principal's membership is resolved from the verified token, never the
/// body (Security ADR §2). The member count is resolved from the roster the
/// membership gate already proved the caller may see, and returned alongside the
/// group (a group is orthogonal to its membership rows — the count is not on the
/// aggregate).
///
/// Never throws; returns a typed [Result].
final class GetGroup {
  /// Creates the use-case over its collaborator.
  const GetGroup({required GroupRepository repository})
    : _repository = repository;

  final GroupRepository _repository;

  /// Reads group [groupId], visible to [principal] as a member, paired with its
  /// current member count.
  Future<Result<GroupWithMemberCount>> call({
    required AuthenticatedUser principal,
    required String groupId,
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

    // Layer 2 (visibility): the caller must be a member. A non-member is
    // refused identically whether or not the group exists (no existence oracle
    // — decision #3, mirror of `leaderboard.not_a_participant`).
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
          'Only a member of the group may view it',
        ),
      );
    }

    // Load the group. The membership gate above already proved existence to
    // this member; a null here would be a storage inconsistency (a membership
    // row with no group), reported as not-a-member so no existence signal leaks
    // and no partial group is fabricated (mirror of `RenameGroup._requireOwner`).
    final groupResult = await _repository.findGroup(gId);
    if (groupResult is Err<Group?>) {
      return Result.err(groupResult.error);
    }
    final group = (groupResult as Ok<Group?>).value;
    if (group == null) {
      return Result.err(
        const AppError.authorization(
          'group.not_a_member',
          'Only a member of the group may view it',
        ),
      );
    }

    // Resolve the current member count from the roster this member may see.
    final rosterResult = await _repository.listMemberships(gId);
    if (rosterResult is Err<List<GroupMembership>>) {
      return Result.err(rosterResult.error);
    }
    final roster = (rosterResult as Ok<List<GroupMembership>>).value;

    return Result.ok(
      GroupWithMemberCount(group: group, memberCount: roster.length),
    );
  }
}
