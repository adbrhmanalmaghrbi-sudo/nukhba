import 'dart:convert';

import 'package:api_client/src/api_error.dart';
import 'package:http/http.dart' as http;
import 'package:shared/shared.dart';

/// Supplies the bearer credential for a request, or `null` for an anonymous
/// call.
///
/// The Supabase access token is owned by the client app (the Auth phase), not
/// this transport — `api_client` never verifies, stores, or refreshes a token;
/// it only attaches whatever the app provides. Async so the app may read it
/// from secure storage / a refresh flow without this layer knowing how.
typedef TokenProvider = Future<String?> Function();

/// The single low-level HTTP transport every domain client is built on.
///
/// Responsibilities (and ONLY these — no business logic, ADR-002 §2.8):
///   * resolve a path against the configured [baseUri];
///   * attach `Authorization: Bearer <token>` (from [tokenProvider]) and
///     `Accept: application/json` / `Content-Type: application/json`;
///   * turn a JSON response into a decoded value via a caller-supplied parser;
///   * dispatch 2xx -> `Ok`, non-2xx -> `Err` (via [decodeError]), and any
///     transport exception -> a transient `Err` (via [networkError]);
///   * be **total** — every method returns a typed [Result] and never throws.
///
/// It holds an injected [http.Client] so tests can drive it with
/// `package:http/testing.dart`'s `MockClient` (a standard, accepted way to test
/// a transport layer — no live socket, no permanent mock in shipped code).
final class ApiTransport {
  /// Creates a transport rooted at [baseUri], using [httpClient] for I/O and
  /// [tokenProvider] to obtain the (optional) bearer token per request.
  ApiTransport({
    required Uri baseUri,
    required http.Client httpClient,
    required TokenProvider tokenProvider,
  }) : _baseUri = baseUri,
       _httpClient = httpClient,
       _tokenProvider = tokenProvider;

  final Uri _baseUri;
  final http.Client _httpClient;
  final TokenProvider _tokenProvider;

  /// Performs `GET [path]` (with optional [query]) and decodes a JSON **object**
  /// body via [parse]. See [_send] for the total error contract.
  Future<Result<T>> getObject<T>(
    String path, {
    Map<String, String>? query,
    required T Function(Map<String, Object?> json) parse,
  }) {
    return _send<T>(
      method: 'GET',
      path: path,
      query: query,
      decode: (body) => _decodeObject(body, parse),
    );
  }

  /// Performs `GET [path]` (with optional [query]) and decodes a JSON **array**
  /// body, mapping each element object via [parseElement].
  Future<Result<List<T>>> getList<T>(
    String path, {
    Map<String, String>? query,
    required T Function(Map<String, Object?> json) parseElement,
  }) {
    return _send<List<T>>(
      method: 'GET',
      path: path,
      query: query,
      decode: (body) => _decodeList(body, parseElement),
    );
  }

  /// Performs `POST [path]` with a JSON object [body] and decodes a JSON
  /// **object** response via [parse].
  Future<Result<T>> postObject<T>(
    String path, {
    required Map<String, Object?> body,
    required T Function(Map<String, Object?> json) parse,
  }) {
    return _send<T>(
      method: 'POST',
      path: path,
      requestBody: body,
      decode: (respBody) => _decodeObject(respBody, parse),
    );
  }

  /// The shared request pipeline. Builds the request, applies auth headers,
  /// executes it, and dispatches the response. Never throws: a transport
  /// exception becomes a transient [Result.err]; a non-2xx becomes a decoded
  /// [Result.err]; a 2xx with an undecodable body becomes a malformed-response
  /// [Result.err].
  Future<Result<T>> _send<T>({
    required String method,
    required String path,
    Map<String, String>? query,
    Map<String, Object?>? requestBody,
    required Result<T> Function(String body) decode,
  }) async {
    final uri = _resolve(path, query);

    final http.Response response;
    try {
      final headers = await _headers(hasBody: requestBody != null);
      response = switch (method) {
        'GET' => await _httpClient.get(uri, headers: headers),
        'POST' => await _httpClient.post(
          uri,
          headers: headers,
          body: jsonEncode(requestBody),
        ),
        _ => throw ArgumentError.value(method, 'method', 'unsupported'),
      };
    } on Object catch (cause) {
      // DNS failure, socket reset, timeout, closed client, etc. — never reached
      // the server (or never got a response): a transient, retryable failure.
      return Result.err(networkError(cause));
    }

    final status = response.statusCode;
    if (status >= 200 && status < 300) {
      return decode(response.body);
    }
    return Result.err(decodeError(status, response.body));
  }

  Uri _resolve(String path, Map<String, String>? query) {
    // Preserve any base path prefix (e.g. a reverse-proxy mount) by joining
    // rather than replacing. `path` is always server-relative (no leading
    // scheme) and starts with '/'.
    final merged = _baseUri.resolve(
      path.startsWith('/') ? path.substring(1) : path,
    );
    if (query == null || query.isEmpty) return merged;
    return merged.replace(
      queryParameters: {...merged.queryParameters, ...query},
    );
  }

  Future<Map<String, String>> _headers({required bool hasBody}) async {
    final headers = <String, String>{'accept': 'application/json'};
    if (hasBody) headers['content-type'] = 'application/json';
    final token = await _tokenProvider();
    if (token != null && token.isNotEmpty) {
      headers['authorization'] = 'Bearer $token';
    }
    return headers;
  }

  static Result<T> _decodeObject<T>(
    String body,
    T Function(Map<String, Object?> json) parse,
  ) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) {
        return Result.err(
          malformedResponse(
            'expected a JSON object, got ${decoded.runtimeType}',
          ),
        );
      }
      return Result.ok(parse(decoded.cast<String, Object?>()));
    } on Object catch (cause) {
      return Result.err(malformedResponse(cause));
    }
  }

  static Result<List<T>> _decodeList<T>(
    String body,
    T Function(Map<String, Object?> json) parseElement,
  ) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! List) {
        return Result.err(
          malformedResponse(
            'expected a JSON array, got ${decoded.runtimeType}',
          ),
        );
      }
      final out = <T>[];
      for (final element in decoded) {
        if (element is! Map) {
          return Result.err(
            malformedResponse(
              'expected each array element to be a JSON object, '
              'got ${element.runtimeType}',
            ),
          );
        }
        out.add(parseElement(element.cast<String, Object?>()));
      }
      return Result.ok(out);
    } on Object catch (cause) {
      return Result.err(malformedResponse(cause));
    }
  }
}
