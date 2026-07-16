import 'dart:io';

import 'package:contracts/contracts.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:domain/domain.dart';
import 'package:server/composition/composition_root.dart';
import 'package:server/http/competition_dto_mapper.dart';
import 'package:server/http/error_envelope.dart';
import 'package:server/http/json_body.dart';
import 'package:shared/shared.dart';

/// `/competitions` collection endpoint.
///
/// * `GET` — list the browsable public competition catalogue (API ADR §2:
///   query intent `ListCompetitions`; added under BLOCKER FA-1 for the client
///   browse scope, read-only, no side effect). Returns a JSON array of
///   [CompetitionDto].
/// * `POST` — create a competition (command intent `CreateCompetition`, not a
///   raw insert). Admin-authorized inside the use-case.
///
/// Both branches are authenticated (bearerAuth middleware). Any other method is
/// `405`.
Future<Response> onRequest(RequestContext context) async {
  return switch (context.request.method) {
    HttpMethod.get => _list(context),
    HttpMethod.post => _create(context),
    _ => Response(statusCode: HttpStatus.methodNotAllowed),
  };
}

/// GET /competitions — the read-only browse catalogue (BLOCKER FA-1).
Future<Response> _list(RequestContext context) async {
  final root = await context.read<Future<CompositionRoot>>();
  final principal = context.read<AuthenticatedUser>();

  final result = await root.listCompetitions(principal: principal);

  return switch (result) {
    Ok<List<Competition>>(:final value) => Response.json(
      body: [for (final c in value) competitionToDto(c).toJson()],
    ),
    Err<List<Competition>>(:final error) => errorResponse(error),
  };
}

/// POST /competitions — create a competition (unchanged command path).
Future<Response> _create(RequestContext context) async {
  final root = await context.read<Future<CompositionRoot>>();
  final principal = context.read<AuthenticatedUser>();

  final bodyResult = await readJsonObject(context.request);
  if (bodyResult is Err<Map<String, Object?>>) {
    return errorResponse(bodyResult.error);
  }
  final body = (bodyResult as Ok<Map<String, Object?>>).value;

  final name = requireString(body, 'name');
  if (name is Err<String>) return errorResponse(name.error);
  final format = requireString(body, 'format');
  if (format is Err<String>) return errorResponse(format.error);
  final visibility = requireString(body, 'visibility');
  if (visibility is Err<String>) return errorResponse(visibility.error);

  final result = await root.createCompetition(
    principal: principal,
    name: (name as Ok<String>).value,
    format: (format as Ok<String>).value,
    visibility: (visibility as Ok<String>).value,
  );

  return switch (result) {
    Ok<Competition>(:final value) => Response.json(
      statusCode: HttpStatus.created,
      body: CompetitionDto(
        id: value.id.value,
        name: value.name,
        format: value.format.wireValue,
        visibility: value.visibility.wireValue,
      ).toJson(),
    ),
    Err<Competition>(:final error) => errorResponse(error),
  };
}
