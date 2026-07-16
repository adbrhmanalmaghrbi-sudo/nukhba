import 'package:domain/src/group/group_id.dart';
import 'package:domain/src/group/group_membership_id.dart';
import 'package:domain/src/group/group_role.dart';
import 'package:domain/src/identity/user_id.dart';
import 'package:shared/shared.dart';

/// A user's membership in a [Group] — its own aggregate root, deliberately
/// separate from the group so a large membership set never requires locking the
/// group aggregate, and mirroring how `Participant` is separate from
/// `Competition` (Database ADR, Section 1).
///
/// A membership binds a platform [userId] to a [groupId] with a per-group
/// [GroupRole] (`owner` for the creator, `member` for everyone who joins via the
/// invite code — Groups decision #2). It is **independent of** competition
/// `Participant` (decision #2): joining a group enrols nobody in any competition,
/// and vice versa. Uniqueness of `(groupId, userId)` — a user is in a group at
/// most once — is enforced structurally in the schema + the join use-case, not
/// re-checked here (an aggregate reasons only about itself; mirror of
/// `Participant`).
///
/// Pure and immutable; state changes produce new values.
final class GroupMembership {
  const GroupMembership._({
    required this.id,
    required this.groupId,
    required this.userId,
    required this.role,
    required this.joinedAt,
  });

  /// Rehydrates a membership from already-trusted stored fields.
  const GroupMembership.fromStored({
    required this.id,
    required this.groupId,
    required this.userId,
    required this.role,
    required this.joinedAt,
  });

  /// Creates the group creator's [GroupRole.owner] membership.
  ///
  /// Used when a group is created — the owner's membership is written
  /// atomically with the group so a group can never exist with no owner row.
  /// [joinedAt] must be UTC.
  static Result<GroupMembership> owner({
    required GroupMembershipId id,
    required GroupId groupId,
    required UserId userId,
    required DateTime joinedAt,
  }) {
    return _create(
      id: id,
      groupId: groupId,
      userId: userId,
      role: GroupRole.owner,
      joinedAt: joinedAt,
    );
  }

  /// Creates a new [GroupRole.member] membership — a user joining via the invite
  /// code (the zero-friction instant join — decision #2). [joinedAt] must be UTC.
  static Result<GroupMembership> join({
    required GroupMembershipId id,
    required GroupId groupId,
    required UserId userId,
    required DateTime joinedAt,
  }) {
    return _create(
      id: id,
      groupId: groupId,
      userId: userId,
      role: GroupRole.member,
      joinedAt: joinedAt,
    );
  }

  static Result<GroupMembership> _create({
    required GroupMembershipId id,
    required GroupId groupId,
    required UserId userId,
    required GroupRole role,
    required DateTime joinedAt,
  }) {
    if (!joinedAt.isUtc) {
      return const Result.err(
        AppError.validation(
          'group.membership_joined_at_not_utc',
          'joinedAt must be provided in UTC',
        ),
      );
    }
    return Result.ok(
      GroupMembership._(
        id: id,
        groupId: groupId,
        userId: userId,
        role: role,
        joinedAt: joinedAt,
      ),
    );
  }

  /// The membership identity.
  final GroupMembershipId id;

  /// The group this membership belongs to.
  final GroupId groupId;

  /// The member's platform user id.
  final UserId userId;

  /// The member's per-group role (`owner`/`member`).
  final GroupRole role;

  /// When the user joined the group (UTC).
  final DateTime joinedAt;

  /// Whether this membership is the group [owner].
  bool get isOwner => role.isOwner;

  @override
  bool operator ==(Object other) =>
      other is GroupMembership &&
      other.id == id &&
      other.groupId == groupId &&
      other.userId == userId &&
      other.role == role &&
      other.joinedAt == joinedAt;

  @override
  int get hashCode => Object.hash(id, groupId, userId, role, joinedAt);

  @override
  String toString() =>
      'GroupMembership(${id.value}, group: ${groupId.value}, '
      'user: ${userId.value}, ${role.wireValue})';
}
