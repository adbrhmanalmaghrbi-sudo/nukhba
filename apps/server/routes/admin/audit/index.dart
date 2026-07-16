import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:domain/domain.dart';
import 'package:server/composition/composition_root.dart';
import 'package:server/http/admin_dto_mapper.dart';
import 'package:server/http/error_envelope.dart';
import 'package:shared/shared.dart';

/// `GET /admin/audit` — read the append-only admin audit trail, newest-first
/// (API ADR §2: a query `ListAuditLog`; Admin Panel decision OPEN-B). Admin-only
/// — the audit trail is itself a privileged surface; the gate
/// (`Authorization.requireRole(principal, PlatformRole.admin)`) lives inside the
/// use-case (Security ADR §2.2; decision §2 #2). A non-admin is refused as
/// `401 auth.insufficient_role` with no oracle.
///
/// An optional `?limit=` query parameter caps the page; the use-case clamps an
/// untrusted value to `[1, ListAuditLog.maxLimit]`, falling back to the default
/// for a null/non-positive/non-integer value, so an audit read never triggers
/// an unbounded scan. A non-integer `limit` is treated as absent (the clamp
/// handles it) rather than a `400`, since the parameter is an optional hint.
///
/// Returns an [AuditLogDto] (`200`); an empty `entries` array is a legitimate
/// empty trail, never an error. `405` on any non-GET method.
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

  final result = await root.listAuditLog(principal: principal, limit: limit);

  return switch (result) {
    Ok<List<AuditEntry>>(:final value) => Response.json(
      body: auditLogJson(value),
    ),
    Err<List<AuditEntry>>(:final error) => errorResponse(error),
  };
}
