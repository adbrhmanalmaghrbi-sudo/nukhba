import 'package:application/src/group/ports/group_repository.dart';
import 'package:application/src/identity/authorization.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// Use-case: rename a group (Application ADR, Section 2: command intent
/// `RenameGroup`).
///
/// **Owner-only** (decision #2): the second authorization layer here is the
/// per-group [GroupRole], NOT the platform-wide `PlatformRole` — a group is a
/// user-owned social object, so "admin of the platform" is irrelevant; the
/// caller must be *this group's* `owner`. The gate is enforced in the use-case
/// (an aggregate cannot see the principal), refusing a non-owner
/// [ErrorKind.authorization] `group.not_owner`, and a non-member identically as
/// `group.not_a_member` (no existence oracle — decision #3).
///
/// Never throws; returns the renamed [Group] as a typed [Result].
final class RenameGroup {
  /// Creates the use-case over its collaborator.
  const RenameGroup({required GroupRepository repository})
    : _repository = repository;

  final GroupRepository _repository;

  /// Renames group [groupId] to [name] on behalf of [principal] (must be owner).
  Future<Result<Group>> call({
    required AuthenticatedUser principal,
    required String groupId,
    required String name,
  }) async {
    final auth = Authorization.requireRole(principal, PlatformRole.user);
    if (auth is Err<AuthenticatedUser>) {
      return Result.err(auth.error);
    }

    final groupIdResult = GroupId.tryParse(groupId);
    if (groupIdResult is Err<GroupId>) {
      return Result.err(groupIdResult.error);
    }
    final gId = (groupIdResult as Ok<GroupId>).value;

    // Membership + owner gate. A non-member and a non-owner member are both
    // refused so a non-member learns nothing about the group's existence.
    final gate = await _requireOwner(gId, principal.userId);
    if (gate is Err<Group>) {
      return Result.err(gate.error);
    }
    final group = (gate as Ok<Group>).value;

    final renamed = group.rename(name);
    if (renamed is Err<Group>) {
      return Result.err(renamed.error);
    }
    final updated = (renamed as Ok<Group>).value;

    final saved = await _repository.updateGroup(updated);
    return switch (saved) {
      Ok<void>() => Result.ok(updated),
      Err<void>(:final error) => Result.err(error),
    };
  }

  /// Resolves the group and asserts [userId] is its owner. A missing membership
  /// → `group.not_a_member`; a member who is not the owner → `group.not_owner`;
  /// an absent group is reported as `group.not_a_member` too (no existence
  /// oracle — decision #3).
  Future<Result<Group>> _requireOwner(GroupId groupId, UserId userId) async {
    final membershipResult = await _repository.findMembership(groupId, userId);
    if (membershipResult is Err<GroupMembership?>) {
      return Result.err(membershipResult.error);
    }
    final membership = (membershipResult as Ok<GroupMembership?>).value;
    if (membership == null) {
      return Result.err(
        const AppError.authorization(
          'group.not_a_member',
          'Only a member of the group may perform this action',
        ),
      );
    }
    if (!membership.isOwner) {
      return Result.err(
        const AppError.authorization(
          'group.not_owner',
          'Only the group owner may perform this action',
        ),
      );
    }

    final groupResult = await _repository.findGroup(groupId);
    if (groupResult is Err<Group?>) {
      return Result.err(groupResult.error);
    }
    final group = (groupResult as Ok<Group?>).value;
    if (group == null) {
      // The membership existed but the group did not — a storage inconsistency.
      // Treat as not-a-member so no existence signal leaks.
      return Result.err(
        const AppError.authorization(
          'group.not_a_member',
          'Only a member of the group may perform this action',
        ),
      );
    }
    return Result.ok(group);
  }
}
