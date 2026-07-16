import 'package:application/src/group/ports/group_repository.dart';
import 'package:application/src/identity/authorization.dart';
import 'package:application/src/social/ports/reaction_repository.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// Query use-case: list the reactions to a round-result within a group
/// (Application ADR §2: a query intent `ListRoundReactions`, separated from
/// commands).
///
/// **Member-only visibility gate (decision #3, mirror of `ListGroupMembers`):**
/// only a member of the group may read its reactions. A caller who is not a
/// member is refused [ErrorKind.authorization] `group.not_a_member`, identically
/// whether or not the group exists — so the response is never a group-existence
/// oracle for a non-member (private-by-default). There is no admin/owner gate —
/// every member sees the banter in their circle (Axiom 1, social-first).
///
/// The principal's membership is resolved from the verified token, never the
/// body (Security ADR §2). The returned reactions are in the repository's
/// reactedAt-ascending order; an empty list means no member has reacted yet (a
/// legitimate result, not an error).
///
/// **Tier-3 (decision #4):** this is a Social read; a failure is confined to
/// this use-case and never blocks a Tier-1 core operation.
///
/// Never throws; returns a typed [Result].
final class ListRoundReactions {
  /// Creates the use-case over its collaborators.
  const ListRoundReactions({
    required ReactionRepository reactions,
    required GroupRepository groups,
  }) : _reactions = reactions,
       _groups = groups;

  final ReactionRepository _reactions;
  final GroupRepository _groups;

  /// Lists the reactions to `(groupId, roundId)`, visible to [principal] as a
  /// member.
  Future<Result<List<Reaction>>> call({
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
          'Only a member of the group may view its reactions',
        ),
      );
    }

    // Read the round's reactions. The membership gate above already proved
    // existence to this member, so this list is theirs to see.
    return _reactions.listReactionsForRound(gId, rId);
  }
}
