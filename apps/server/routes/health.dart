import 'dart:io';

import 'package:contracts/contracts.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:domain/domain.dart';
import 'package:server/composition/composition_root.dart';
import 'package:shared/shared.dart';

/// GET /health — the Milestone 0 end-to-end proof slice.
///
/// Flows: controller -> CheckHealth use-case -> HealthRepository port ->
/// PostgresHealthRepository adapter -> Postgres `SELECT 1`
/// (Roadmap ADR, Milestone 0 exit criterion).
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final root = await context.read<Future<CompositionRoot>>();
  final result = await root.checkHealth();

  return switch (result) {
    Ok<HealthCheck>(:final value) => Response.json(
      statusCode: value.status == HealthStatus.healthy
          ? HttpStatus.ok
          : HttpStatus.serviceUnavailable,
      body: HealthResponseDto(
        status: value.status.name,
        databaseReachable: value.databaseReachable,
      ).toJson(),
    ),
    // CheckHealth never returns Err by design, but we handle it exhaustively.
    Err<HealthCheck>(:final error) => Response.json(
      statusCode: HttpStatus.serviceUnavailable,
      body: {'error': error.code, 'message': error.message},
    ),
  };
}
