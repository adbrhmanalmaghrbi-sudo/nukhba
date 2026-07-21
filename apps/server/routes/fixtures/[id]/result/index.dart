import 'dart:io';

import 'package:contracts/contracts.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:domain/domain.dart';
import 'package:server/composition/composition_root.dart';
import 'package:server/http/error_envelope.dart';
import 'package:server/http/json_body.dart';
import 'package:shared/shared.dart';

/// PUT /fixtures/{id}/result — record (or idempotently correct) the actual
/// final score of a fixture (API ADR §2: command intent `RecordFixtureResult`).
/// Admin-only, enforced inside the use-case (Axioms 2/5: the client never
/// submits a result; only an admin ingests the actual scoreline).
///
/// This is the ingestion side of the Axiom-3 football seam (Next-Task decision
/// 2026-07-11, option (a)): with no Football-Data phase before Scoring, the
/// actual scoreline enters through this minimal admin command rather than an
/// automated feed. The fixture is named by the path id only — a result carries
/// no competition/round reference, so the same result feeds every round the
/// fixture belongs to (Axiom 3). `PUT` (not `POST`) because the operation is an
/// idempotent upsert on the fixture id: recording the same scoreline twice, or
/// correcting a mistyped one before scoring, converges on one stored row.
///
/// Body: `{ "home_goals": int, "away_goals": int }` — the two goal tallies
/// only; no points, no round, no participant. Returns the stored
/// [FixtureResultDto] (`200`); a scoreline outside the accepted range surfaces
/// as `400` `scoring.result_out_of_range`/`scoring.result_negative` via the
/// shared error envelope.
///
/// The `/fixtures` subtree is already behind `bearerAuth`
/// (`routes/fixtures/_middleware.dart`), which provides the verified
/// [AuthenticatedUser]; an unauthenticated request never reaches this handler.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.put) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final root = await context.read<Future<CompositionRoot>>();
  final principal = context.read<AuthenticatedUser>();

  final bodyResult = await readJsonObject(context.request);
  if (bodyResult is Err<Map<String, Object?>>) {
    return errorResponse(bodyResult.error);
  }
  final body = (bodyResult as Ok<Map<String, Object?>>).value;

  final homeResult = requireInt(body, 'home_goals');
  if (homeResult is Err<int>) {
    return errorResponse(homeResult.error);
  }
  final awayResult = requireInt(body, 'away_goals');
  if (awayResult is Err<int>) {
    return errorResponse(awayResult.error);
  }

  final result = await root.recordFixtureResult(
    principal: principal,
    fixtureId: id,
    homeGoals: (homeResult as Ok<int>).value,
    awayGoals: (awayResult as Ok<int>).value,
  );

  return switch (result) {
    Ok<FixtureResult>(:final value) => Response.json(
      body: FixtureResultDto(
        fixtureId: value.fixture.value,
        homeGoals: value.homeGoals,
        awayGoals: value.awayGoals,
      ).toJson(),
    ),
    Err<FixtureResult>(:final error) => errorResponse(error),
  };
}
