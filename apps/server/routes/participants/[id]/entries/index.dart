import 'dart:io';

import 'package:application/application.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:domain/domain.dart';
import 'package:server/composition/composition_root.dart';
import 'package:server/http/error_envelope.dart';
import 'package:server/http/ledger_dto_mapper.dart';
import 'package:shared/shared.dart';

/// GET /participants/{id}/entries — read a participant's **append-only entry
/// stream** in the ledger's stream order (occurred-at ascending, then entry id
/// for a stable tie-break) — API ADR §2: a query, separated from the post
/// command.
///
/// Every entry is an immutable movement (Axiom 5); this read never mutates the
/// stream. An empty list means the participant has no ledger movements yet
/// (distinct from a not-found: a participant the caller owns but who has never
/// been credited legitimately returns `200` with `entries: []`).
///
/// The visibility gate lives entirely inside `ReadParticipantLedger`: the
/// ledger is a participant's *personal* competitive record, so the gate is
/// **ownership** — a caller may read only a participant they own (Security ADR
/// §2). A missing participant, or one owned by someone else, is reported
/// identically as `401` `ledger.participant_not_found`, so the response is never
/// an enumeration/ownership oracle. This route only wires the verified principal
/// and the participant id and shapes the result.
///
/// The `/participants` subtree is already behind `bearerAuth`
/// (`routes/participants/_middleware.dart`), which provides the
/// [AuthenticatedUser]; an unauthenticated request never reaches this handler.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final root = await context.read<Future<CompositionRoot>>();
  final principal = context.read<AuthenticatedUser>();

  final result = await root.readParticipantLedger.entriesOf(
    principal: principal,
    participantId: id,
  );

  return switch (result) {
    Ok<List<PointEntry>>(:final value) => Response.json(
      body: participantEntriesJson(id, value),
    ),
    Err<List<PointEntry>>(:final error) => errorResponse(error),
  };
}
