import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:domain/domain.dart';
import 'package:server/composition/composition_root.dart';
import 'package:server/http/error_envelope.dart';
import 'package:shared/shared.dart';

/// `GET /notifications/unread_count` — read the caller's OWN unread-notification
/// count (API ADR §2: a query, for a badge/indicator).
///
/// **Recipient-only (Notifications decision #4):** the count is scoped entirely
/// to the verified principal inside `GetUnreadCount` — no group/season
/// membership check, recipient bound from the token, never a body or path
/// (Security ADR §2). This route makes no authorization decision.
///
/// The count is not an entity, so the response is a minimal
/// `{ "unread_count": int }` object rather than one of the notification DTOs
/// (mirroring the reactions route's `{ "removed": bool }` shape); the full
/// `NotificationListDto` (which also carries the count) is `GET /notifications`.
/// The value is always `>= 0`; zero is a legitimate result (all read, or none
/// exist).
///
/// **Tier-3 degradation (decision #4):** a failure is returned as the uniform
/// error envelope (`503` for transient) and never blocks a Tier-1 core
/// operation. `405` on any non-GET method.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final root = await context.read<Future<CompositionRoot>>();
  final principal = context.read<AuthenticatedUser>();

  final result = await root.getUnreadCount(principal: principal);

  return switch (result) {
    Ok<int>(:final value) => Response.json(body: {'unread_count': value}),
    Err<int>(:final error) => errorResponse(error),
  };
}
