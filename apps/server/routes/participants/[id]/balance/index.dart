import 'dart:io';

import 'package:application/application.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:domain/domain.dart';
import 'package:server/composition/composition_root.dart';
import 'package:server/http/error_envelope.dart';
import 'package:server/http/ledger_dto_mapper.dart';
import 'package:shared/shared.dart';

/// GET /participants/{id}/balance — read a participant's **projected balance**
/// over their append-only ledger stream (API ADR §2: a query, separated from
/// the post command).
///
/// The balance is a **projection**, never a stored mutable number (Axiom 5):
/// the repository computes it as the signed sum over the participant's immutable
/// entries, and its value equals the domain `LedgerBalance.project` over the
/// same stream.
///
/// The visibility gate lives entirely inside `ReadParticipantLedger`: the
/// ledger is a participant's *personal* competitive record, so the gate is
/// **ownership** — a caller may read only a participant they own (Security ADR
/// §2). A missing participant, or one owned by someone else, is reported
/// identically as `401` `ledger.participant_not_found`, so the response is never
/// an enumeration/ownership oracle. This route only wires the verified principal
/// and the participant id and shapes the result — it makes no authorization
/// decision of its own.
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

  final result = await root.readParticipantLedger.balanceOf(
    principal: principal,
    participantId: id,
  );

  return switch (result) {
    Ok<LedgerBalance>(:final value) => Response.json(
      body: balanceJson(id, value),
    ),
    Err<LedgerBalance>(:final error) => errorResponse(error),
  };
}
