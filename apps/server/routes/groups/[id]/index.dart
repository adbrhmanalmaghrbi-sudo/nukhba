import 'dart:io';

import 'package:application/application.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:domain/domain.dart';
import 'package:server/composition/composition_root.dart';
import 'package:server/http/error_envelope.dart';
import 'package:server/http/group_dto_mapper.dart';
import 'package:server/http/json_body.dart';
import 'package:shared/shared.dart';

/// Routes for a single group resource:
///   * `GET  /groups/{id}` — read the group (member-gated).
///   * `PATCH /groups/{id}` — rename the group (owner-only).
///
/// Both authorization gates live entirely inside the use-cases (Security ADR §2)
/// — the route makes no authz decision, only wires the verified principal + the
/// path id and shapes the result. The `/groups` subtree is already behind
/// `bearerAuth` (`routes/groups/_middleware.dart`).
Future<Response> onRequest(RequestContext context, String id) async {
  return switch (context.request.method) {
    HttpMethod.get => _get(context, id),
    HttpMethod.patch => _rename(context, id),
    _ => Future.value(Response(statusCode: HttpStatus.methodNotAllowed)),
  };
}

/// GET /groups/{id} — read the group, visible only to a member (Groups
/// decision #3: a non-member is refused `401` `group.not_a_member` identically
/// whether or not the group exists — no existence oracle). Returns the
/// [GroupDto] with the real `member_count` from the roster; the invite code is
/// surfaced because the caller is a member (it is a capability they already
/// hold).
Future<Response> _get(RequestContext context, String id) async {
  final root = await context.read<Future<CompositionRoot>>();
  final principal = context.read<AuthenticatedUser>();

  final result = await root.getGroup(principal: principal, groupId: id);

  return switch (result) {
    Ok<GroupWithMemberCount>(:final value) => Response.json(
      body: groupToDto(value.group, memberCount: value.memberCount).toJson(),
    ),
    Err<GroupWithMemberCount>(:final error) => errorResponse(error),
  };
}

/// PATCH /groups/{id} — rename the group (API ADR §2: command intent
/// `RenameGroup`). **Owner-only** (Groups decision #2): the gate is the
/// per-group [GroupRole], enforced in the use-case — a non-owner member is
/// refused `401` `group.not_owner`, a non-member `401` `group.not_a_member`
/// (no existence oracle — decision #3). Body: `{ "name": string }`. Returns the
/// renamed [GroupDto]; the `member_count` is unchanged by a rename, so the
/// route echoes the roster size the caller must be able to see (it is an owner,
/// hence a member). A rename does not add/remove members, so re-reading the
/// roster only to count it would be redundant — the count is not part of the
/// rename's invariant. We therefore surface it as the caller-visible member
/// count via a follow-on read of the group.
Future<Response> _rename(RequestContext context, String id) async {
  final root = await context.read<Future<CompositionRoot>>();
  final principal = context.read<AuthenticatedUser>();

  final bodyResult = await readJsonObject(context.request);
  if (bodyResult is Err<Map<String, Object?>>) {
    return errorResponse(bodyResult.error);
  }
  final body = (bodyResult as Ok<Map<String, Object?>>).value;

  final name = requireString(body, 'name');
  if (name is Err<String>) {
    return errorResponse(name.error);
  }

  final result = await root.renameGroup(
    principal: principal,
    groupId: id,
    name: (name as Ok<String>).value,
  );

  return switch (result) {
    // Resolve the current member count for the renamed group via the member-
    // gated read (the caller is the owner, hence a member — the gate passes).
    Ok<Group>() => _reReadForCount(root, principal, id, result as Ok<Group>),
    Err<Group>(:final error) => errorResponse(error),
  };
}

/// After a successful rename, shape the response with the group's real member
/// count. The rename already proved the caller is the owner (a member), so the
/// member-gated [CompositionRoot.getGroup] read succeeds; on the unlikely event
/// it does not (a concurrent deletion), fall back to the renamed group with a
/// minimum count of 1 (an existing group always has at least its owner) so the
/// successful rename is still reported.
Future<Response> _reReadForCount(
  CompositionRoot root,
  AuthenticatedUser principal,
  String id,
  Ok<Group> renamed,
) async {
  final read = await root.getGroup(principal: principal, groupId: id);
  return switch (read) {
    Ok<GroupWithMemberCount>(:final value) => Response.json(
      body: groupToDto(
        // Use the just-renamed value as the source of truth for the name,
        // paired with the freshly-read member count.
        renamed.value,
        memberCount: value.memberCount,
      ).toJson(),
    ),
    Err<GroupWithMemberCount>() => Response.json(
      body: groupToDto(renamed.value, memberCount: 1).toJson(),
    ),
  };
}
