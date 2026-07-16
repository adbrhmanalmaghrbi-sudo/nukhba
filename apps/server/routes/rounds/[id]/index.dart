import 'dart:io';

import 'package:contracts/contracts.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:domain/domain.dart';
import 'package:server/composition/composition_root.dart';
import 'package:server/http/competition_dto_mapper.dart';
import 'package:server/http/error_envelope.dart';
import 'package:shared/shared.dart';

/// GET /rounds/{id} — read a single round (API ADR §2: query intent `GetRound`).
///
/// Added under BLOCKER FA-1 (2026-07-13) for the client's Prediction-submit
/// scope: the client renders a round (its status + prediction deadline) before
/// showing the prediction form. Read-only, no side effect, no new domain rule.
/// Authenticated (bearerAuth middleware; the `/rounds` subtree already applies
/// it via `rounds/_middleware.dart`). A missing round surfaces
/// `competition.round_not_found` (an `invariant`), which is built here directly
/// as a true `404` (same discipline as `competitions/[id]` and the prediction
/// read surface — no ADR-gated new `ErrorKind`). Returns the [RoundDto] (`200`).
///
/// This is a NEW read-only route; no existing route or command path is touched.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final root = await context.read<Future<CompositionRoot>>();
  final principal = context.read<AuthenticatedUser>();

  final result = await root.getRound(principal: principal, roundId: id);

  return switch (result) {
    Ok<Round>(:final value) => Response.json(body: roundToDto(value).toJson()),
    // A missing round is genuinely "resource not found". The repository surfaces
    // it as an `invariant` (`competition.round_not_found`), which the closed
    // `ErrorKind` set would otherwise map to 409; a browse read wants a true 404.
    // So that one code is built directly here, keeping the versioned
    // `ErrorResponseDto` body. Every other error keeps the uniform envelope
    // mapping (e.g. a malformed id → 400).
    Err<Round>(:final error) =>
      error.code == 'competition.round_not_found'
          ? Response.json(
              statusCode: HttpStatus.notFound,
              body: ErrorResponseDto(
                code: error.code,
                message: error.message,
              ).toJson(),
            )
          : errorResponse(error),
  };
}
