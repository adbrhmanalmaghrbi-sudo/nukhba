import 'dart:io';

import 'package:contracts/contracts.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:domain/domain.dart';
import 'package:server/composition/composition_root.dart';
import 'package:server/http/competition_dto_mapper.dart';
import 'package:server/http/error_envelope.dart';
import 'package:server/http/json_body.dart';
import 'package:shared/shared.dart';

/// `/seasons/{id}/rounds` collection endpoint.
///
/// * `GET` — list the season's rounds, ordered by 1-based sequence (API ADR §2:
///   query intent `ListSeasonRounds`; added under the FA-1 season/round browse
///   scope closure — read-only, no side effect). A season with no rounds, or one
///   that does not exist, yields a legitimate empty JSON array (no existence
///   oracle — the use-case never 404s a round list). Returns a JSON array of
///   [RoundDto] (ruleset *version* only — the opaque frozen snapshot is never
///   exposed).
/// * `POST` — open a round in the season, freezing the ruleset (command intent
///   `OpenRound`, not a raw insert). Admin-authorized inside the use-case.
///
/// Both branches are authenticated (bearerAuth middleware; the `/seasons`
/// subtree already applies it via `seasons/_middleware.dart`). Any other method
/// is `405`.
Future<Response> onRequest(RequestContext context, String id) async {
  return switch (context.request.method) {
    HttpMethod.get => _list(context, id),
    HttpMethod.post => _create(context, id),
    _ => Response(statusCode: HttpStatus.methodNotAllowed),
  };
}

/// GET /seasons/{id}/rounds — the read-only round browse (FA-1 closure).
Future<Response> _list(RequestContext context, String id) async {
  final root = await context.read<Future<CompositionRoot>>();
  final principal = context.read<AuthenticatedUser>();

  final result = await root.listSeasonRounds(
    principal: principal,
    seasonId: id,
  );

  return switch (result) {
    Ok<List<Round>>(:final value) => Response.json(
      body: [for (final round in value) roundToDto(round).toJson()],
    ),
    Err<List<Round>>(:final error) => errorResponse(error),
  };
}

/// POST /seasons/{id}/rounds — open a round, freezing the ruleset (unchanged
/// command path; API ADR §2: command intent `OpenRound`). Admin-only (use-case
/// layer).
///
/// Path: season id. Body: `{ "sequence", "prediction_deadline" }` where
/// `prediction_deadline` is an ISO-8601 instant. The edge parses the deadline
/// to a UTC [DateTime] (a transport concern); the domain re-asserts UTC and the
/// 1-based sequence rule. Returns the created [RoundDto] (`201`).
Future<Response> _create(RequestContext context, String id) async {
  final root = await context.read<Future<CompositionRoot>>();
  final principal = context.read<AuthenticatedUser>();

  final bodyResult = await readJsonObject(context.request);
  if (bodyResult is Err<Map<String, Object?>>) {
    return errorResponse(bodyResult.error);
  }
  final body = (bodyResult as Ok<Map<String, Object?>>).value;

  final sequence = requireInt(body, 'sequence');
  if (sequence is Err<int>) return errorResponse(sequence.error);

  final deadlineResult = _parseDeadline(body['prediction_deadline']);
  if (deadlineResult is Err<DateTime>) {
    return errorResponse(deadlineResult.error);
  }

  final result = await root.openRound(
    principal: principal,
    seasonId: id,
    sequence: (sequence as Ok<int>).value,
    predictionDeadline: (deadlineResult as Ok<DateTime>).value,
  );

  return switch (result) {
    Ok<Round>(:final value) => Response.json(
      statusCode: HttpStatus.created,
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

/// Parses the untrusted `prediction_deadline` field into a UTC [DateTime].
///
/// Requires an ISO-8601 string; anything else is a validation failure. The
/// parsed instant is normalized to UTC so the domain's UTC invariant holds
/// regardless of the offset the caller supplied.
Result<DateTime> _parseDeadline(Object? raw) {
  if (raw is! String) {
    return const Result.err(
      AppError.validation(
        'request.field_missing',
        'Field "prediction_deadline" is required and must be an ISO-8601 string',
      ),
    );
  }
  final parsed = DateTime.tryParse(raw);
  if (parsed == null) {
    return const Result.err(
      AppError.validation(
        'request.deadline_malformed',
        'Field "prediction_deadline" must be a valid ISO-8601 instant',
      ),
    );
  }
  return Result.ok(parsed.toUtc());
}
