import 'dart:io';

import 'package:application/application.dart';
import 'package:contracts/contracts.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:domain/domain.dart';
import 'package:server/composition/composition_root.dart';
import 'package:server/http/error_envelope.dart';
import 'package:server/http/json_body.dart';
import 'package:server/http/prediction_dto_mapper.dart';
import 'package:shared/shared.dart';

/// `/rounds/{id}/predictions` — the participant-facing prediction surface for a
/// round (API ADR §2: use-case API of domain intents, command/query separated).
///
/// * `POST` — submit (or idempotently amend) the caller's prediction via the
///   `SubmitPrediction` command. The body is a [SubmitPredictionCommandDto]
///   (only the predicted scorelines); the participant is resolved server-side
///   from the verified principal and the round's season, **never** from the
///   body, so a caller can never predict on someone else's behalf (Security
///   ADR §2 / Axioms 2/5). Points are never accepted or returned. Returns the
///   stored [PredictionDto] (`200`) — one row per round (Axiom 4), so both a
///   first submission and an amendment resolve to the same resource.
/// * `GET` — read the caller's own prediction via `GetMyPrediction` (any round
///   status; self-read is safe). Returns the [PredictionDto] (`200`); when the
///   caller has joined but not yet predicted (or is not a participant) there is
///   no such resource, so this responds `404` `prediction.not_found` — letting
///   the client distinguish "nothing submitted yet" from a transport error.
///
/// The whole `/rounds` subtree is already behind `bearerAuth` via
/// `routes/rounds/_middleware.dart`, which provides the verified
/// [AuthenticatedUser]; an unauthenticated request never reaches this handler.
Future<Response> onRequest(RequestContext context, String id) async {
  return switch (context.request.method) {
    HttpMethod.post => _submit(context, id),
    HttpMethod.get => _getMine(context, id),
    _ => Response(statusCode: HttpStatus.methodNotAllowed),
  };
}

Future<Response> _submit(RequestContext context, String roundId) async {
  final root = await context.read<Future<CompositionRoot>>();
  final principal = context.read<AuthenticatedUser>();

  final bodyResult = await readJsonObject(context.request);
  if (bodyResult is Err<Map<String, Object?>>) {
    return errorResponse(bodyResult.error);
  }
  final body = (bodyResult as Ok<Map<String, Object?>>).value;

  // Parse the command DTO defensively: a malformed/missing scores array is a
  // transport-validation failure (400), not an exception. The edge owns only
  // this parsing; every business rule lives in the use-case.
  final scoresResult = _parseScores(body);
  if (scoresResult is Err<List<FixtureScoreInput>>) {
    return errorResponse(scoresResult.error);
  }
  final scores = (scoresResult as Ok<List<FixtureScoreInput>>).value;

  final result = await root.submitPrediction(
    principal: principal,
    roundId: roundId,
    scores: scores,
  );

  return switch (result) {
    Ok<PredictionView>(:final value) => Response.json(
      body: predictionViewToJson(value),
    ),
    Err<PredictionView>(:final error) => errorResponse(error),
  };
}

Future<Response> _getMine(RequestContext context, String roundId) async {
  final root = await context.read<Future<CompositionRoot>>();
  final principal = context.read<AuthenticatedUser>();

  final result = await root.getMyPrediction(
    principal: principal,
    roundId: roundId,
  );

  return switch (result) {
    // A joined-but-not-yet-predicted caller (or a non-participant) has no such
    // resource. This is genuinely "resource not found", so it is a real HTTP
    // 404 built directly — NOT routed through `errorResponse`, whose closed
    // `ErrorKind` set maps every `invariant` to 409 (there is no distinct
    // not-found kind, and adding one is an ADR-gated architecture change). The
    // body still uses the versioned `ErrorResponseDto` shape for uniformity, so
    // the client sees a stable `prediction.not_found` code with a true 404.
    Ok<PredictionView?>(:final value) =>
      value == null
          ? Response.json(
              statusCode: HttpStatus.notFound,
              body: const ErrorResponseDto(
                code: 'prediction.not_found',
                message: 'You have not submitted a prediction for this round',
              ).toJson(),
            )
          : Response.json(body: predictionViewToJson(value)),
    Err<PredictionView?>(:final error) => errorResponse(error),
  };
}

/// Turns the untrusted JSON body into a validated list of [FixtureScoreInput],
/// mapping any structural problem (missing/typed-wrong `fixture_scores`, a
/// non-object entry, missing goal fields) to an [ErrorKind.validation] error.
/// Value ranges and domain rules (fixture-in-round, completeness) are the
/// use-case's job — this only asserts the wire contract.
Result<List<FixtureScoreInput>> _parseScores(Map<String, Object?> body) {
  final raw = body['fixture_scores'];
  if (raw is! List) {
    return const Result.err(
      AppError.validation(
        'request.field_missing',
        'Field "fixture_scores" is required and must be an array',
      ),
    );
  }

  final inputs = <FixtureScoreInput>[];
  for (final entry in raw) {
    if (entry is! Map) {
      return const Result.err(
        AppError.validation(
          'request.body_not_object',
          'Each entry in "fixture_scores" must be a JSON object',
        ),
      );
    }
    final map = entry.cast<String, Object?>();
    final fixtureId = map['fixture_id'];
    final homeGoals = map['home_goals'];
    final awayGoals = map['away_goals'];
    if (fixtureId is! String) {
      return const Result.err(
        AppError.validation(
          'request.field_missing',
          'Each fixture score requires a string "fixture_id"',
        ),
      );
    }
    if (homeGoals is! int || awayGoals is! int) {
      return const Result.err(
        AppError.validation(
          'request.field_missing',
          'Each fixture score requires integer "home_goals" and "away_goals"',
        ),
      );
    }
    inputs.add(
      FixtureScoreInput(
        fixtureId: fixtureId,
        homeGoals: homeGoals,
        awayGoals: awayGoals,
      ),
    );
  }
  return Result.ok(inputs);
}
