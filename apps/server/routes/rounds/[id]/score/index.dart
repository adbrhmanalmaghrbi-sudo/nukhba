import 'dart:io';

import 'package:application/application.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:domain/domain.dart';
import 'package:server/composition/composition_root.dart';
import 'package:server/http/error_envelope.dart';
import 'package:server/http/scoring_dto_mapper.dart';
import 'package:shared/shared.dart';

/// POST /rounds/{id}/score — score every prediction in a round (API ADR §2:
/// command intent `ScoreRound`). Admin-only, enforced inside the use-case
/// (Axioms 2/5: only the platform computes and writes points).
///
/// Modelled as a sub-resource command (`/score`) rather than a status mutation,
/// keeping the surface a use-case API of domain intents rather than
/// tables-over-HTTP (mirrors `/rounds/{id}/lock`). There is **no request body**:
/// the caller submits no points and no results — the actual scorelines were
/// ingested separately by the admin `RecordFixtureResult` command, and the
/// points are computed server-side from the round's frozen ruleset. Accepting a
/// body of points would breach the integrity boundary, so none is read.
///
/// Idempotent: re-scoring an already-`scored` round recomputes the same
/// deterministic result and re-persists it without a spurious transition
/// conflict (see `ScoreRound`). Returns the computed [RoundScoresDto] (`200`) so
/// an admin sees exactly what was written; a not-yet-locked round surfaces as
/// `409` `scoring.round_not_locked`, a missing result as `409`
/// `scoring.results_incomplete`, via the shared error envelope.
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

  final result = await root.scoreRound(principal: principal, roundId: id);

  return switch (result) {
    Ok<List<RoundScore>>(:final value) => Response.json(
      body: roundScoresToJson(id, value),
    ),
    Err<List<RoundScore>>(:final error) => errorResponse(error),
  };
}
