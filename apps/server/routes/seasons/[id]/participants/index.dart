import 'dart:io';

import 'package:contracts/contracts.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:domain/domain.dart';
import 'package:server/composition/composition_root.dart';
import 'package:server/http/error_envelope.dart';
import 'package:shared/shared.dart';

/// POST /seasons/{id}/participants — enrol the calling user into the season
/// (API ADR §2: command intent `JoinCompetition`). Any authenticated user may
/// join (Axiom 1, social-first); the enrolled user is taken from the verified
/// token, never the body, so a caller can never enrol someone else.
///
/// Idempotent: a repeated join returns the existing enrolment (`200`) rather
/// than erroring; a first-time join returns `201`. There is no request body —
/// the season is in the path and the user is the principal.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final root = await context.read<Future<CompositionRoot>>();
  final principal = context.read<AuthenticatedUser>();

  final result = await root.joinCompetition(principal: principal, seasonId: id);

  return switch (result) {
    Ok<Participant>(:final value) => Response.json(
      statusCode: HttpStatus.created,
      body: ParticipantDto(
        id: value.id.value,
        seasonId: value.seasonId.value,
        userId: value.userId.value,
        status: value.status.wireValue,
        joinedAt: value.joinedAt.toIso8601String(),
      ).toJson(),
    ),
    Err<Participant>(:final error) => errorResponse(error),
  };
}
