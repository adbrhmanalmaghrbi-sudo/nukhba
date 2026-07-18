import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:domain/domain.dart';
import 'package:server/composition/composition_root.dart';
import 'package:server/http/error_envelope.dart';
import 'package:server/http/ledger_dto_mapper.dart';
import 'package:shared/shared.dart';

/// POST /rounds/{id}/ledger — post a **scored** round to the append-only Ledger
/// (API ADR §2: command intent `PostRoundToLedger`). Admin-only, enforced
/// inside the use-case (Axioms 2/5: only the platform turns scores into the
/// protected competitive record — the client never posts points).
///
/// This is the Scoring → Ledger seam, realized as a **separate, explicit
/// command** rather than a domain event emitted by `ScoreRound` (the
/// architecture decision ratified in §2 before any code — it keeps Scoring's
/// public surface untouched and stays inside the event-driven boundary, ADR
/// 0002). Modelled as a sub-resource command (`/ledger`) rather than a status
/// mutation, keeping the surface a use-case API of domain intents rather than
/// tables-over-HTTP (mirrors `/rounds/{id}/score`).
///
/// There is deliberately **no request body**: the caller submits no points —
/// the amounts are copied server-side from the round's already-persisted frozen
/// `RoundScore`s. Accepting a body of points would breach the integrity
/// boundary (Axiom 2), so none is read.
///
/// **Idempotent** (Axiom 4): re-posting an already-posted round appends nothing
/// new — the response's `appended_entries` is empty, and no participant is
/// double-credited (the ledger is append-only; the dedupe is a *skip*, never an
/// update/delete — Axiom 5). Returns the [PostRoundToLedgerResponseDto] (`200`)
/// so an admin sees exactly which entries this post appended; a not-yet-scored
/// round surfaces as `409` `ledger.round_not_scored`, a non-admin as `401`
/// `auth.insufficient_role`, via the shared error envelope.
///
/// The `/rounds` subtree is already behind `bearerAuth`
/// (`routes/rounds/_middleware.dart`), which provides the verified
/// [AuthenticatedUser]; an unauthenticated request never reaches this handler.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final root = await context.read<Future<CompositionRoot>>();
  final principal = context.read<AuthenticatedUser>();

  final result = await root.postRoundToLedger(
    principal: principal,
    roundId: id,
  );

  return switch (result) {
    Ok<List<PointEntry>>(:final value) => Response.json(
      body: postRoundToLedgerResponseJson(id, value),
    ),
    Err<List<PointEntry>>(:final error) => errorResponse(error),
  };
}
