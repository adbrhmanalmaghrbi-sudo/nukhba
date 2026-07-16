import 'dart:io';

import 'package:application/application.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:domain/domain.dart';
import 'package:server/composition/composition_root.dart';
import 'package:server/http/error_envelope.dart';
import 'package:server/http/scoring_dto_mapper.dart';
import 'package:shared/shared.dart';

/// GET /rounds/{id}/scores — read every participant's computed score for a
/// **scored** round (API ADR §2: a query, separated from the score command).
///
/// The visibility gate lives entirely inside `GetRoundScores`: scores are
/// meaningful only once the round is `scored` (exposing them earlier would
/// reveal partial or absent results — Axiom 2, the integrity boundary), so a
/// not-yet-scored round is rejected `409` `scoring.round_not_scored`; and only
/// a participant of the round's season may see the competing pool, so a
/// non-participant is rejected `401` `scoring.not_a_participant`. This route
/// only wires the verified principal and the round id and shapes the result —
/// it makes no authorization decision of its own.
///
/// The `/rounds` subtree is already behind `bearerAuth`
/// (`routes/rounds/_middleware.dart`), which provides the [AuthenticatedUser];
/// an unauthenticated request never reaches this handler. Returns the
/// [RoundScoresDto] (`200`); an empty `scores` array means the round is scored
/// but no one predicted, distinct from the `409` "too early" case.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final root = await context.read<Future<CompositionRoot>>();
  final principal = context.read<AuthenticatedUser>();

  final result = await root.getRoundScores(principal: principal, roundId: id);

  return switch (result) {
    Ok<List<RoundScore>>(:final value) => Response.json(
      body: roundScoresToJson(id, value),
    ),
    Err<List<RoundScore>>(:final error) => errorResponse(error),
  };
}
