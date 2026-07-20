import 'package:dart_frog/dart_frog.dart';

/// This server is an API-only backend (ADR-007: hosting is separated from
/// the app). It no longer serves the Flutter Web build — that is deployed
/// independently to GitHub Pages. `/` exists only as a human-friendly
/// landing/sanity check; real health checks should use `/health`.
Future<Response> onRequest(RequestContext context) async {
  return Response.json(
    body: {'service': 'nukhba-api', 'status': 'ok', 'health': '/health'},
  );
}
