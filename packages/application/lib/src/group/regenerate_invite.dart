import 'package:application/src/common/invite_code_generator.dart';
import 'package:application/src/group/ports/group_repository.dart';
import 'package:application/src/identity/authorization.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// Use-case: regenerate a group's invite code (Application ADR, Section 2:
/// command intent `RegenerateInvite`).
///
/// **Owner-only** (decision #2): as with `RenameGroup`, the gate is the
/// per-group [GroupRole] (`owner`), enforced in the use-case, not the platform
/// role. Rotating the code **revokes** the previously-shared link — the old code
/// no longer resolves to the group (`findByInviteCode` returns null for it), so
/// an owner can cut off a leaked invite. A non-owner is refused
/// `group.not_owner`, a non-member `group.not_a_member` (no existence oracle —
/// decision #3).
///
/// The fresh code is server-generated via [InviteCodeGenerator] (never
/// client-supplied). Never throws; returns the updated [Group] (carrying the new
/// code) as a typed [Result].
final class RegenerateInvite {
  /// Creates the use-case over its collaborators.
  const RegenerateInvite({
    required GroupRepository repository,
    required InviteCodeGenerator inviteCodeGenerator,
  }) : _repository = repository,
       _inviteCodeGenerator = inviteCodeGenerator;

  final GroupRepository _repository;
  final InviteCodeGenerator _inviteCodeGenerator;

  /// Regenerates the invite code of group [groupId] on behalf of [principal]
  /// (must be owner).
  Future<Result<Group>> call({
    required AuthenticatedUser principal,
    required String groupId,
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

    final groupResult = await _repository.findGroup(gId);
    if (groupResult is Err<Group?>) {
      return Result.err(groupResult.error);
    }
    final group = (groupResult as Ok<Group?>).value;
    if (group == null) {
      return Result.err(
        const AppError.authorization(
          'group.not_a_member',
          'Only a member of the group may perform this action',
        ),
      );
    }

    final rotated = group.regenerateInvite(_inviteCodeGenerator.newCode());

    final saved = await _repository.updateGroup(rotated);
    return switch (saved) {
      Ok<void>() => Result.ok(rotated),
      Err<void>(:final error) => Result.err(error),
    };
  }
}
