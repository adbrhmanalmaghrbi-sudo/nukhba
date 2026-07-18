import 'dart:io';

import 'package:application/application.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:domain/domain.dart';
import 'package:server/composition/composition_root.dart';
import 'package:server/http/error_envelope.dart';
import 'package:server/http/group_dto_mapper.dart';
import 'package:shared/shared.dart';

/// POST /groups/{id}/invite/regenerate — rotate a group's shareable invite code
/// (API ADR §2: command intent `RegenerateInvite`).
///
/// **Owner-only** (Groups decision #2): the gate is the per-group [GroupRole]
/// (`owner`), enforced entirely inside `RegenerateInvite`, never the platform
/// role — a non-owner member is refused `401` `group.not_owner`, a non-member
/// `401` `group.not_a_member` (no existence oracle — decision #3). Rotating the
/// code **revokes** the previously-shared link: the old code no longer resolves
/// to the group, so an owner can cut off a leaked invite (decision #3).
///
/// There is NO request body — the fresh code is server-generated via the
/// crypto-strong `InviteCodeGenerator` (Security ADR §2: the invite code is
/// server-owned, never client-supplied). Returns the updated [GroupDto]
/// carrying the new invite code (`200`); the `member_count` is unchanged by a
/// rotation, so — mirroring the rename route — the response echoes the roster
/// size the caller (an owner, hence a member) is entitled to see, resolved via
/// the member-gated group read.
///
/// The `/groups` subtree is already behind `bearerAuth`
/// (`routes/groups/_middleware.dart`), which provides the verified
/// [AuthenticatedUser]; an unauthenticated request never reaches this handler.
/// `405` on any non-POST method.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final root = await context.read<Future<CompositionRoot>>();
  final principal = context.read<AuthenticatedUser>();

  final result = await root.regenerateInvite(principal: principal, groupId: id);

  return switch (result) {
    // The rotation already proved the caller is the owner (a member), so shape
    // the response with the group's real member count via the member-gated
    // read; the just-rotated value is the source of truth for the new code.
    Ok<Group>() => _reReadForCount(root, principal, id, result),
    Err<Group>(:final error) => errorResponse(error),
  };
}

/// After a successful rotation, shape the response with the group's real member
/// count. The rotation already proved the caller is the owner (a member), so
/// the member-gated [CompositionRoot.getGroup] read succeeds; on the unlikely
/// event it does not (a concurrent deletion), fall back to the rotated group
/// with a minimum count of 1 (an existing group always has at least its owner)
/// so the successful rotation is still reported — always surfacing the new
/// invite code from the rotated value.
Future<Response> _reReadForCount(
  CompositionRoot root,
  AuthenticatedUser principal,
  String id,
  Ok<Group> rotated,
) async {
  final read = await root.getGroup(principal: principal, groupId: id);
  return switch (read) {
    Ok<GroupWithMemberCount>(:final value) => Response.json(
      // Use the just-rotated value as the source of truth for the invite
      // code, paired with the freshly-read member count.
      body: groupToDto(rotated.value, memberCount: value.memberCount).toJson(),
    ),
    Err<GroupWithMemberCount>() => Response.json(
      body: groupToDto(rotated.value, memberCount: 1).toJson(),
    ),
  };
}
