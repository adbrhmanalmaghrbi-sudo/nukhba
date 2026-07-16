import 'dart:io';

import 'package:contracts/contracts.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:domain/domain.dart';
import 'package:server/composition/composition_root.dart';
import 'package:server/http/competition_dto_mapper.dart';
import 'package:server/http/error_envelope.dart';
import 'package:server/http/json_body.dart';
import 'package:shared/shared.dart';

/// `/rounds/{id}/fixtures` collection endpoint.
///
/// * `GET` — list the fixtures linked to the round, in matchday order (API ADR
///   §2: query intent `ListRoundFixtures`; added under BLOCKER FA-1 for the
///   client's Prediction-submit scope — read-only, no side effect). A round with
///   no linked fixtures, or one that does not exist, yields a legitimate empty
///   JSON array (no existence oracle — the use-case never 404s a fixture list).
/// * `POST` — link a fixture to the round (command intent `LinkFixtureToRound`;
///   Axiom 3: the only place Competition names a fixture). Admin-only (use-case
///   layer).
///
/// Both branches are authenticated (bearerAuth middleware; the `/rounds` subtree
/// already applies it via `rounds/_middleware.dart`). Any other method is `405`.
Future<Response> onRequest(RequestContext context, String id) async {
  return switch (context.request.method) {
    HttpMethod.get => _list(context, id),
    HttpMethod.post => _create(context, id),
    _ => Response(statusCode: HttpStatus.methodNotAllowed),
  };
}

/// GET /rounds/{id}/fixtures — the read-only fixtures browse (BLOCKER FA-1).
Future<Response> _list(RequestContext context, String id) async {
  final root = await context.read<Future<CompositionRoot>>();
  final principal = context.read<AuthenticatedUser>();

  final result = await root.listRoundFixtures(
    principal: principal,
    roundId: id,
  );

  return switch (result) {
    Ok<List<RoundFixture>>(:final value) => Response.json(
      body: [for (final link in value) roundFixtureToDto(link).toJson()],
    ),
    Err<List<RoundFixture>>(:final error) => errorResponse(error),
  };
}

/// POST /rounds/{id}/fixtures — link a fixture to the round (unchanged command
/// path).
Future<Response> _create(RequestContext context, String id) async {
  final root = await context.read<Future<CompositionRoot>>();
  final principal = context.read<AuthenticatedUser>();

  final bodyResult = await readJsonObject(context.request);
  if (bodyResult is Err<Map<String, Object?>>) {
    return errorResponse(bodyResult.error);
  }
  final body = (bodyResult as Ok<Map<String, Object?>>).value;

  final fixtureId = requireString(body, 'fixture_id');
  if (fixtureId is Err<String>) return errorResponse(fixtureId.error);
  final displayOrder = requireInt(body, 'display_order');
  if (displayOrder is Err<int>) return errorResponse(displayOrder.error);

  final result = await root.linkFixtureToRound(
    principal: principal,
    roundId: id,
    fixtureId: (fixtureId as Ok<String>).value,
    displayOrder: (displayOrder as Ok<int>).value,
  );

  return switch (result) {
    Ok<RoundFixture>(:final value) => Response.json(
      statusCode: HttpStatus.created,
      body: RoundFixtureDto(
        roundId: value.roundId.value,
        fixtureId: value.fixture.value,
        displayOrder: value.displayOrder,
      ).toJson(),
    ),
    Err<RoundFixture>(:final error) => errorResponse(error),
  };
}
