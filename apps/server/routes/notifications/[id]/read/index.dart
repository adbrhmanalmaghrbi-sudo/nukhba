import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:domain/domain.dart';
import 'package:server/composition/composition_root.dart';
import 'package:server/http/error_envelope.dart';
import 'package:shared/shared.dart';

/// `POST /notifications/{id}/read` — mark the caller's OWN notification read
/// (API ADR §2: a command `MarkNotificationRead`; the one client-safe Tier-3
/// mutation — decision #4).
///
/// **Recipient-only, no existence oracle (decision #4):** every authorization
/// decision lives inside `MarkNotificationRead` — the recipient is bound from
/// the verified token (never the body/path), and a notification that is foreign
/// or does not exist is refused identically as `401 notification.not_found`
/// (mirror of the Ledger self-read `participant_not_found`, NOT a 404-vs-403
/// leak). This route makes no authorization decision; it only wires the
/// principal + path id and shapes the result.
///
/// **Idempotent (decision #3):** marking an already-read notification is a
/// success that does NOT reset the original read timestamp. The boolean is
/// echoed so a client can tell an actual transition (`true`) from a no-op
/// (`false`); both are `200`.
///
/// No request body (the id is the path capability; the recipient is the token).
/// A malformed id is a `400` (validation) from `NotificationId.tryParse` inside
/// the use-case. `405` on any non-POST method.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final root = await context.read<Future<CompositionRoot>>();
  final principal = context.read<AuthenticatedUser>();

  final result = await root.markNotificationRead(
    principal: principal,
    notificationId: id,
  );

  return switch (result) {
    // true  = transitioned unread→read; false = already read (idempotent no-op).
    Ok<bool>(:final value) => Response.json(body: {'read': value}),
    Err<bool>(:final error) => errorResponse(error),
  };
}
