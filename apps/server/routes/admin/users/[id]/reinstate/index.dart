import 'dart:io';

import 'package:contracts/contracts.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:domain/domain.dart';
import 'package:server/composition/composition_root.dart';
import 'package:server/http/admin_dto_mapper.dart';
import 'package:server/http/error_envelope.dart';
import 'package:server/http/json_body.dart';
import 'package:shared/shared.dart';

/// `POST /admin/users/{id}/reinstate` — reverse a suspension (API ADR §2:
/// command intent `ReinstateUser`; the mirror of `SuspendUser` — Admin Panel
/// decision OPEN-A #1). Admin-only, enforced inside the use-case (Security ADR
/// §2.3; decision §2 #2); reuses the same request shape as suspend so the
/// reversal is equally attributable (a reason is likewise mandatory, recorded
/// in the audit trail — decision OPEN-B).
///
/// The target user id is the path capability; the acting admin is bound from
/// the verified token (never a body); the ONLY client-supplied value is the
/// mandatory [SuspendUserRequestDto.reason]. A missing/blank reason is a `400`
/// validation failure; an unknown target is `409` `admin.user_not_found`. The
/// transition does NOT gate on role (a suspended admin can be reinstated).
///
/// **Idempotent:** reinstating an already-active user converges and echoes
/// `active`. Returns the [UserSanctionResultDto] (`200`). `405` on any non-POST
/// method.
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

  final dto = SuspendUserRequestDto.fromJson(body);

  final result = await root.reinstateUser(
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
