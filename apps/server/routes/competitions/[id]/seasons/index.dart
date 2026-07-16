import 'dart:io';

import 'package:contracts/contracts.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:domain/domain.dart';
import 'package:server/composition/composition_root.dart';
import 'package:server/http/competition_dto_mapper.dart';
import 'package:server/http/error_envelope.dart';
import 'package:server/http/json_body.dart';
import 'package:shared/shared.dart';

/// `/competitions/{id}/seasons` collection endpoint.
///
/// * `GET` — list the competition's seasons, ordered by label (API ADR §2:
///   query intent `ListCompetitionSeasons`; added under the FA-1 season/round
///   browse scope closure — read-only, no side effect). A competition with no
///   seasons, or one that does not exist, yields a legitimate empty JSON array
///   (no existence oracle — the use-case never 404s a season list). Returns a
///   JSON array of [SeasonDto].
/// * `POST` — start a season under the competition (command intent
///   `StartSeason`, not a raw insert). Admin-authorized inside the use-case.
///
/// Both branches are authenticated (bearerAuth middleware). Any other method is
/// `405`.
Future<Response> onRequest(RequestContext context, String id) async {
  return switch (context.request.method) {
    HttpMethod.get => _list(context, id),
    HttpMethod.post => _create(context, id),
    _ => Response(statusCode: HttpStatus.methodNotAllowed),
  };
}

/// GET /competitions/{id}/seasons — the read-only season browse (FA-1 closure).
Future<Response> _list(RequestContext context, String id) async {
  final root = await context.read<Future<CompositionRoot>>();
  final principal = context.read<AuthenticatedUser>();

  final result = await root.listCompetitionSeasons(
    principal: principal,
    competitionId: id,
  );

  return switch (result) {
    Ok<List<CompetitionSeason>>(:final value) => Response.json(
      body: [for (final season in value) seasonToDto(season).toJson()],
    ),
    Err<List<CompetitionSeason>>(:final error) => errorResponse(error),
  };
}

/// POST /competitions/{id}/seasons — start a season (unchanged command path;
/// API ADR §2: command intent `StartSeason`). Admin-only (use-case layer).
///
/// The competition id comes from the path; the season [label] from the body
/// `{ "label" }`. Returns the created [SeasonDto] (`201`) or the error envelope.
Future<Response> _create(RequestContext context, String id) async {
  final root = await context.read<Future<CompositionRoot>>();
  final principal = context.read<AuthenticatedUser>();

  final bodyResult = await readJsonObject(context.request);
  if (bodyResult is Err<Map<String, Object?>>) {
    return errorResponse(bodyResult.error);
  }
  final body = (bodyResult as Ok<Map<String, Object?>>).value;

  final label = requireString(body, 'label');
  if (label is Err<String>) return errorResponse(label.error);

  final result = await root.startSeason(
    principal: principal,
    competitionId: id,
    label: (label as Ok<String>).value,
  );

  return switch (result) {
    Ok<CompetitionSeason>(:final value) => Response.json(
      statusCode: HttpStatus.created,
      body: SeasonDto(
        id: value.id.value,
        competitionId: value.competitionId.value,
        label: value.label,
      ).toJson(),
    ),
    Err<CompetitionSeason>(:final error) => errorResponse(error),
  };
}
