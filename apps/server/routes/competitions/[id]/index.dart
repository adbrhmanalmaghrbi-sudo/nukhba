import 'dart:io';

import 'package:contracts/contracts.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:domain/domain.dart';
import 'package:server/composition/composition_root.dart';
import 'package:server/http/competition_dto_mapper.dart';
import 'package:server/http/error_envelope.dart';
import 'package:shared/shared.dart';

/// GET /competitions/{id} — read a single competition (API ADR §2: query intent
/// `GetCompetition`).
///
/// Added under BLOCKER FA-1 (2026-07-13) for the client's browse-detail read —
/// read-only, no side effect, no new domain rule. Authenticated (bearerAuth
/// middleware; the `/competitions` subtree already applies it). A missing
/// competition surfaces `competition.not_found` (an `invariant`), which the
/// error envelope maps to `404`. Returns the [CompetitionDto] (`200`).
///
/// This is a NEW read sibling; the collection's `POST` command path is
/// untouched.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final root = await context.read<Future<CompositionRoot>>();
  final principal = context.read<AuthenticatedUser>();

  final result = await root.getCompetition(
    principal: principal,
    competitionId: id,
  );

  return switch (result) {
    Ok<Competition>(:final value) => Response.json(
      body: competitionToDto(value).toJson(),
    ),
    // A missing competition is genuinely "resource not found". The repository
    // surfaces it as an `invariant` (`competition.not_found`), which the closed
    // `ErrorKind` set would otherwise map to 409; a browse read wants a true
    // 404. So that one code is built directly here (same discipline as the
    // prediction read surface — no ADR-gated new `ErrorKind`), keeping the
    // versioned `ErrorResponseDto` body. Every other error keeps the uniform
    // envelope mapping (e.g. a malformed id → 400).
    Err<Competition>(:final error) =>
      error.code == 'competition.not_found'
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
