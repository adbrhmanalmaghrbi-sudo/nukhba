import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:domain/domain.dart';
import 'package:server/composition/composition_root.dart';
import 'package:server/http/error_envelope.dart';
import 'package:server/http/group_dto_mapper.dart';
import 'package:server/http/json_body.dart';
import 'package:shared/shared.dart';

/// POST /groups — create a new private group (API ADR §2: command intent
/// `CreateGroup`, not a raw insert).
///
/// *Any* authenticated user may create a group — this is the social-first entry
/// point (Axiom 1): a user spins up a private circle of friends, not an admin
/// (the authority gate lives inside the use-case). The creator becomes the sole
/// [GroupRole.owner]; their owner membership is written atomically with the
/// group (Groups decision #2). The `ownerId` is taken from the verified token,
/// never the body (Security ADR §2), so a caller can never create a group owned
/// by someone else. The group id and the shareable invite code are
/// server-generated (decision #2/#3), never client-supplied.
///
/// Body: `{ "name": string }`. Returns the created [GroupDto] (`200`) with
/// `member_count` = 1 (the freshly-created group has exactly one member, its
/// owner), or the uniform error envelope whose status is derived from the
/// domain error kind (a malformed/oversized name → `400`; an astronomically
/// unlikely invite-code collision → `409` `group.invite_code_conflict`).
///
/// The `/groups` subtree is already behind `bearerAuth`
/// (`routes/groups/_middleware.dart`), which provides the verified
/// [AuthenticatedUser]; an unauthenticated request never reaches this handler.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

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

  final result = await root.createGroup(
    principal: principal,
    name: (name as Ok<String>).value,
  );

  return switch (result) {
    // A newly-created group has exactly one member — its owner (decision #2).
    Ok<Group>(:final value) => Response.json(
      body: groupToDto(value, memberCount: 1).toJson(),
    ),
    Err<Group>(:final error) => errorResponse(error),
  };
}
