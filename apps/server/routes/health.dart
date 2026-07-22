import 'dart:io';

import 'package:contracts/contracts.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:domain/domain.dart';
import 'package:server/composition/composition_root.dart';
import 'package:shared/shared.dart';

Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }
  try {
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
      Err<HealthCheck>(:final error) => Response.json(
        statusCode: HttpStatus.serviceUnavailable,
        body: {'error': error.code, 'message': error.message},
      ),
    };
  } catch (e, st) {
      // اللوق فقط للتشخيص الداخلي — لا تُسرّب التفاصيل للعميل أبداً.
      print('health check failed: $e\n$st');
      return Response.json(
        statusCode: HttpStatus.internalServerError,
        body: {'error': 'internal_error'},
      );
    }
}
