import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:domain/domain.dart';
import 'package:server/composition/composition_root.dart';
import 'package:server/http/error_envelope.dart';
import 'package:server/http/ledger_dto_mapper.dart';
import 'package:shared/shared.dart';

/// `GET /admin/participants/{id}/ledger` — the narrow cross-user
/// read-for-support (API ADR §2: a query `ViewParticipantLedger`; Admin Panel
/// decision OPEN-A #3: an admin reads a SINGLE participant's ledger by explicit
/// id, read-only, never a bulk/export view, and the read is ITSELF audited).
/// Admin-only, enforced inside the use-case (Security ADR §2.2/§2.3; decision
/// §2 #2).
///
/// This is deliberately a DIFFERENT endpoint from `GET /participants/{id}/
/// entries` (whose gate is self-read ownership — a caller sees only their own
/// ledger). Here the caller is an admin reading SOMEONE ELSE'S ledger, a
/// widening every prior read path forbade, which is why decision OPEN-A #3
/// ratified it narrow and made every such read leave an audit trace: the
/// use-case records a `participant_ledger_viewed` audit entry BEFORE serving the
/// data, and a failed audit write refuses the read (never silently serves
/// un-traced cross-user data — Security ADR §2.4).
///
/// An optional `?reason=` query parameter is passed through to the audit record
/// (decision OPEN-A #3 mandates the read be audited, not that it carry a
/// justification string; when supplied it must be non-blank — the domain
/// `AuditEntry.create` enforces this). An unknown participant is `409`
/// `admin.participant_not_found` (no enumeration oracle).
///
/// Returns the participant's append-only entry stream shaped identically to the
/// self-read endpoint (`participantEntriesJson`) — one consistent ledger wire
/// shape (`200`); an empty list means no movements yet, never an error. `405`
/// on any non-GET method.
///
/// The `/admin` subtree is already behind `bearerAuth`
/// (`routes/admin/_middleware.dart`), which provides the verified
/// [AuthenticatedUser]; an unauthenticated request never reaches this handler.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final root = await context.read<Future<CompositionRoot>>();
  final principal = context.read<AuthenticatedUser>();

  // Optional support justification; an absent value stays null (the read is
  // audited regardless — decision OPEN-A #3). A supplied value must be
  // non-blank (the domain audit-entry constructor enforces this).
  final reason = context.request.uri.queryParameters['reason'];

  final result = await root.viewParticipantLedger(
    principal: principal,
    participantId: id,
    reason: reason,
  );

  return switch (result) {
    Ok<List<PointEntry>>(:final value) => Response.json(
      body: participantEntriesJson(id, value),
    ),
    Err<List<PointEntry>>(:final error) => errorResponse(error),
  };
}
