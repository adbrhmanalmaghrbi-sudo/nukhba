import 'dart:io';

import 'package:application/application.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:domain/domain.dart';
import 'package:server/composition/composition_root.dart';
import 'package:server/http/error_envelope.dart';
import 'package:server/http/prediction_dto_mapper.dart';
import 'package:shared/shared.dart';

/// GET /rounds/{id}/predictions/all — list every participant's prediction for a
/// **locked** round (API ADR §2: a query, separated from the submit command).
///
/// The visibility gate lives entirely inside `ListRoundPredictions`: while a
/// round is open every forecast is private (revealing them early would let a
/// caller copy another's prediction — Axiom 2, the integrity boundary), so an
/// open round is rejected `401` `prediction.round_not_locked`; and only a
/// participant of the round's season may see the competing pool. This route
/// only wires the verified principal and the round id and shapes the result —
/// it makes no authorization decision of its own.
///
/// The `/rounds` subtree is already behind `bearerAuth`
/// (`routes/rounds/_middleware.dart`), which provides the [AuthenticatedUser];
/// an unauthenticated request never reaches this handler. Returns a JSON array
/// of [PredictionDto] (`200`); an empty array means the round is locked but no
/// one predicted, distinct from the `401` "too early" case.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final root = await context.read<Future<CompositionRoot>>();
  final principal = context.read<AuthenticatedUser>();

  final result = await root.listRoundPredictions(
    principal: principal,
    roundId: id,
  );

  return switch (result) {
    Ok<List<PredictionView>>(:final value) => Response.json(
      body: [for (final view in value) predictionViewToJson(view)],
    ),
    Err<List<PredictionView>>(:final error) => errorResponse(error),
  };
}
