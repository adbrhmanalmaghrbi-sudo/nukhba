import 'dart:io';

import 'package:contracts/contracts.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:domain/domain.dart';
import 'package:server/composition/composition_root.dart';
import 'package:server/http/admin_dto_mapper.dart';
import 'package:server/http/error_envelope.dart';
import 'package:server/http/json_body.dart';
import 'package:shared/shared.dart';

/// `POST /admin/users/{id}/suspend` — suspend a user (API ADR §2: command
/// intent `SuspendUser`; Admin Panel decision OPEN-A #1: a reversible sanction
/// carrying a mandatory reason). Admin-only, enforced inside the use-case
/// (`Authorization.requireRole(principal, PlatformRole.admin)` first — Security
/// ADR §2.3; decision §2 #2).
///
/// The target user id is the path capability; the acting admin is bound from
/// the verified token (never a body); the ONLY client-supplied value is the
/// mandatory [SuspendUserRequestDto.reason] (decision OPEN-A #1 — the same
/// reason feeds the immutable audit record, decision OPEN-B). A missing/blank
/// reason is a `400` validation failure from the use-case (never a silent empty
/// sanction); a `service` principal cannot be suspended (`409`
/// `identity.cannot_suspend_service`); an unknown target is `409`
/// `admin.user_not_found`.
///
/// **Idempotent:** re-suspending an already-suspended user converges (the
/// domain transition returns an equal value) and echoes `suspended`. Returns
/// the [UserSanctionResultDto] (`200`). `405` on any non-POST method.
///
/// The `/admin` subtree is already behind `bearerAuth`
/// (`routes/admin/_middleware.dart`), which provides the verified
/// [AuthenticatedUser]; an unauthenticated request never reaches this handler.
Future<Response> onRequest(RequestContext context, String id) async {
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

  // The reason is nullable on the wire so a missing field is reported by the
  // use-case as a validation failure (`admin.sanction_reason_required`), never
  // a silent empty sanction. A wrong-type value is likewise treated as absent.
  final dto = SuspendUserRequestDto.fromJson(body);

  final result = await root.suspendUser(
    principal: principal,
    targetUserId: id,
    reason: dto.reason,
  );

  return switch (result) {
    Ok<User>(:final value) => Response.json(
      body: userSanctionResultJson(value),
    ),
    Err<User>(:final error) => errorResponse(error),
  };
}
