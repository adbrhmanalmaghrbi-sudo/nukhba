import 'dart:convert';

import 'package:api_client/api_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// One captured outbound request, for asserting method/path/headers/body.
final class CapturedRequest {
  CapturedRequest(this.request);

  final http.Request request;

  String get method => request.method;
  Uri get url => request.url;
  Map<String, String> get headers => request.headers;
  String get body => request.body;
}

/// Builds an [ApiTransport] whose I/O is served entirely by a
/// `package:http/testing.dart` [MockClient] — no live socket. The
/// [handler] decides the canned response (or throws to simulate a transport
/// failure); every request seen is appended to [captured].
///
/// This is the standard, accepted way to drive a transport layer under test
/// (documented in `ApiTransport`'s own doc comment); the mock lives only in the
/// test tree, never in shipped code.
({ApiTransport transport, List<CapturedRequest> captured}) buildTransport(
  Future<http.Response> Function(http.Request request) handler, {
  String? token = 'test-token',
  Uri? baseUri,
}) {
  final captured = <CapturedRequest>[];
  final client = MockClient((request) async {
    captured.add(CapturedRequest(request));
    return handler(request);
  });
  final transport = ApiTransport(
    baseUri: baseUri ?? Uri.parse('https://api.test.example/'),
    httpClient: client,
    tokenProvider: () async => token,
  );
  return (transport: transport, captured: captured);
}

/// A `200 OK` JSON response from an encodable [json] map/list.
http.Response okJson(Object json) => http.Response(
  jsonEncode(json),
  200,
  headers: const {'content-type': 'application/json'},
);

/// A non-2xx response carrying the server's versioned error envelope
/// (`code` + `message` + `schema_version`) — mirrors
/// `apps/server/lib/http/error_envelope.dart`.
http.Response errorEnvelope(int status, String code, String message) =>
    http.Response(
      jsonEncode({'schema_version': 1, 'code': code, 'message': message}),
      status,
      headers: const {'content-type': 'application/json'},
    );

/// A bare status response with NO body (e.g. a route's `405` method guard, or
/// an opaque proxy error) — exercises the synthetic-error path in
/// `decodeError`.
http.Response bareStatus(int status) => http.Response('', status);
