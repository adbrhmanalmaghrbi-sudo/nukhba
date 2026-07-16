import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:domain/domain.dart';
import 'package:server/composition/composition_root.dart';
import 'package:server/http/error_envelope.dart';
import 'package:server/http/notification_dto_mapper.dart';
import 'package:shared/shared.dart';

/// `GET /notifications` — read the caller's OWN notification list, newest-first,
/// plus their whole-inbox unread count (API ADR §2: a query).
///
/// **Recipient-only (Notifications decision #4):** the list is scoped entirely to
/// the verified principal inside `ListMyNotifications` — there is no
/// group/season membership check, and the recipient is bound from the token,
/// never a body or path (Security ADR §2). This route makes no authorization
/// decision; it only wires the principal + optional `?limit=` and shapes the
/// result.
///
/// An optional `?limit=` query parameter caps the page; the use-case clamps an
/// untrusted value to `[1, ListMyNotifications.maxLimit]`, falling back to the
/// default for a null/non-positive/non-integer value, so a Tier-3 read never
/// triggers an unbounded scan (decision #4). A non-integer `limit` is treated as
/// absent (the clamp handles it) rather than a `400`, since the parameter is an
/// optional hint, not a required field.
///
/// The unread count is read separately (`GetUnreadCount`) so the response's
/// `unread_count` reflects the recipient's WHOLE inbox, not just the returned
/// page. Both reads are recipient-scoped; a failure in either is a Tier-3
/// degradation returned as the uniform error envelope (`503` for transient), and
/// it never blocks a Tier-1 core operation.
///
/// Returns a [NotificationListDto] (`200`); an empty `notifications` array is a
/// legitimate empty inbox, never an error. `405` on any non-GET method.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final root = await context.read<Future<CompositionRoot>>();
  final principal = context.read<AuthenticatedUser>();

  // Optional hint; a missing/non-integer value is passed as null so the
  // use-case applies its default. int.tryParse returns null for anything that
  // is not a plain integer — exactly the "treat as absent" behaviour.
  final rawLimit = context.request.uri.queryParameters['limit'];
  final limit = rawLimit == null ? null : int.tryParse(rawLimit);

  final listResult = await root.listMyNotifications(
    principal: principal,
    limit: limit,
  );
  if (listResult is Err<List<Notification>>) {
    return errorResponse(listResult.error);
  }
  final notifications = (listResult as Ok<List<Notification>>).value;

  final countResult = await root.getUnreadCount(principal: principal);
  if (countResult is Err<int>) {
    return errorResponse(countResult.error);
  }
  final unreadCount = (countResult as Ok<int>).value;

  return Response.json(
    body: notificationListJson(
      principal.userId.value,
      notifications,
      unreadCount,
    ),
  );
}
