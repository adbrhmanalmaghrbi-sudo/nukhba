import 'package:application/src/group/ports/group_repository.dart';
import 'package:application/src/identity/authorization.dart';
import 'package:application/src/social/ports/reaction_repository.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// Command use-case: a group member removes their own reaction to a
/// round-result (Application ADR §2: command intent `RemoveReaction`).
///
/// *Any* authenticated user may act (Axiom 1, social-first), but only as a
/// **member** of the group the reaction is scoped to — the exact ratified
/// `group.not_a_member` gate (Groups decision #3), reused via
/// [GroupRepository.findMembership], with NO existence oracle (a non-member is
/// refused identically whether or not the group/round exists). The author is
/// taken from the verified token, never the body (Security ADR §2), so a caller
/// can only ever remove **their own** reaction — the storage port is keyed on
/// `(groupId, roundId, userId)` with `userId` bound from the principal.
///
/// Idempotent (Application ADR §2; decision #2): removing an absent reaction is
/// a no-op success, so a retried remove converges. The boolean carried in the
/// [Result] reports whether a row was actually removed (`true`) or there was
/// nothing to remove (`false`) — both are successful outcomes.
///
/// **Tier-3 (decision #4):** this is a Social write; a failure is confined to
/// this use-case and never blocks a Tier-1 core operation.
///
/// Never throws; returns a typed [Result].
final class RemoveReaction {
  /// Creates the use-case over its collaborators.
  const RemoveReaction({
    required ReactionRepository reactions,
    required GroupRepository groups,
  }) : _reactions = reactions,
       _groups = groups;

  final ReactionRepository _reactions;
  final GroupRepository _groups;

  /// Removes [principal]'s reaction to `(groupId, roundId)`, if any.
  Future<Result<bool>> call({
    required AuthenticatedUser principal,
    required String groupId,
    required String roundId,
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

    final rIdResult = RoundId.tryParse(roundId);
    if (rIdResult is Err<RoundId>) {
      return Result.err(rIdResult.error);
    }
    final rId = (rIdResult as Ok<RoundId>).value;

    // Layer 2 (visibility): the caller must be a member of the group. Refused
    // identically whether or not the group exists (no existence oracle —
    // decision #3, mirror of `ListGroupMembers`/`ReactToRound`).
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
          'Only a member of the group may remove a reaction in it',
        ),
      );
    }

    // Remove only the caller's own reaction (userId bound from the principal).
    // Idempotent: `Ok(false)` when there was nothing to remove.
    return _reactions.removeReaction(gId, rId, principal.userId);
  }
}
