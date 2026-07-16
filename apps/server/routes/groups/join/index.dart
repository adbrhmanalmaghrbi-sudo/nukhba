import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:domain/domain.dart';
import 'package:server/composition/composition_root.dart';
import 'package:server/http/error_envelope.dart';
import 'package:server/http/group_dto_mapper.dart';
import 'package:server/http/json_body.dart';
import 'package:shared/shared.dart';

/// POST /groups/join — join a private group via its shareable invite code (API
/// ADR §2: command intent `JoinGroupByInvite`).
///
/// The invite code is the **capability** (Groups decision #3): possession of a
/// valid code grants access, so the code — carried in the body, not a group id
/// in the path — is the input. An unknown/rotated code is refused identically
/// whether or not any group exists (`409` `group.invite_invalid`, no existence
/// oracle). The joining user is taken from the verified token, never the body
/// (Security ADR §2), so a caller can never enrol someone else.
///
/// Idempotent (decision #2, zero-friction instant join): a user already a member
/// gets their existing membership back rather than a duplicate or an error — a
/// retried join converges on one membership. The owner "joining" their own group
/// via the code is a no-op that returns their owner membership.
///
/// Body: `{ "invite_code": string }`. Returns the caller's [GroupMembershipDto]
/// (`200`), or the uniform error envelope (`400` for a missing/malformed field;
/// `409` `group.invite_invalid` for an unknown code).
///
/// The `/groups` subtree is already behind `bearerAuth`
/// (`routes/groups/_middleware.dart`).
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

  final code = requireString(body, 'invite_code');
  if (code is Err<String>) {
    return errorResponse(code.error);
  }

  final result = await root.joinGroupByInvite(
    principal: principal,
    inviteCode: (code as Ok<String>).value,
  );

  return switch (result) {
    Ok<GroupMembership>(:final value) => Response.json(
      body: membershipToDto(value).toJson(),
    ),
    Err<GroupMembership>(:final error) => errorResponse(error),
  };
}
