import 'dart:io';

import 'package:contracts/contracts.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:domain/domain.dart';
import 'package:server/composition/composition_root.dart';
import 'package:server/http/error_envelope.dart';
import 'package:shared/shared.dart';

/// POST /rounds/{id}/lock — lock an open round once its prediction window closes
/// (API ADR §2: command intent `LockRound`). Admin-only (use-case layer).
///
/// This is modelled as a sub-resource command (`/lock`) rather than a status
/// mutation, keeping the surface a use-case API of domain intents rather than
/// tables-over-HTTP. No body. Returns the updated [RoundDto] (`200`); a stale
/// or concurrent attempt surfaces as `409` via the error envelope.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final root = await context.read<Future<CompositionRoot>>();
  final principal = context.read<AuthenticatedUser>();

  final result = await root.lockRound(principal: principal, roundId: id);

  return switch (result) {
    Ok<Round>(:final value) => Response.json(
      body: RoundDto(
        id: value.id.value,
        seasonId: value.seasonId.value,
        sequence: value.sequence,
        predictionDeadline: value.predictionDeadline.toIso8601String(),
        status: value.status.wireValue,
        rulesetVersion: value.ruleset.rulesetVersion,
      ).toJson(),
    ),
    Err<Round>(:final error) => errorResponse(error),
  };
}
