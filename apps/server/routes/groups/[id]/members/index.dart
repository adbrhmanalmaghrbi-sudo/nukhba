import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:domain/domain.dart';
import 'package:server/composition/composition_root.dart';
import 'package:server/http/error_envelope.dart';
import 'package:server/http/group_dto_mapper.dart';
import 'package:shared/shared.dart';

/// GET /groups/{id}/members — list a group's members (API ADR §2: a query,
/// separated from the group commands).
///
/// **Member-only visibility gate (Groups decision #3, mirror of the
/// season-membership gate):** only a member of the group may read its roster. A
/// non-member is refused `401` `group.not_a_member` identically whether or not
/// the group exists (no existence oracle). There is no admin/owner gate — every
/// member may see who else is in their circle (Axiom 1, social-first). The gate
/// lives entirely inside `ListGroupMembers`; this route makes no authz decision.
///
/// Returns a [GroupMembersDto] — the roster in the server-defined order
/// (joinedAt ascending, the owner first). The `/groups` subtree is already
/// behind `bearerAuth` (`routes/groups/_middleware.dart`).
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final root = await context.read<Future<CompositionRoot>>();
  final principal = context.read<AuthenticatedUser>();

  final result = await root.listGroupMembers(principal: principal, groupId: id);

  return switch (result) {
    Ok<List<GroupMembership>>(:final value) => Response.json(
      body: groupMembersJson(id, value),
    ),
    Err<List<GroupMembership>>(:final error) => errorResponse(error),
  };
}
