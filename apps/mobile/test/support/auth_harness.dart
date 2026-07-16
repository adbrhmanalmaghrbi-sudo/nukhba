/// Test harness for the Auth slice.
///
/// Builds a `ProviderScope` whose networking is served entirely by a
/// `package:http/testing.dart` [MockClient] (no live socket) and whose token
/// store is an in-memory fake — the same standard, accepted approach the
/// `api_client` package uses for its own transport tests (`MockClient` never
/// ships in production code).
///
/// It overrides the three seams the [SessionController] depends on:
///   * `tokenStoreProvider` → a seedable [InMemoryTokenStore] (so "restore a
///     saved session at boot" is testable);
///   * `apiTransportProvider` → an [ApiTransport] over the [MockClient] whose
///     [TokenProvider] reads that same store (so the `/me` probe carries the
///     just-persisted token, exactly as production does);
///   * `authApiProvider` → an [AuthApi] over that transport.
///
/// The [MockClient] handler is supplied per test to canned a `200` `/me`, a
/// `401`, or a thrown transport failure.
library;

import 'dart:convert';

import 'package:api_client/api_client.dart';
import 'package:contracts/contracts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/core/auth/token_store.dart';
import 'package:mobile/core/providers.dart';

/// One captured outbound request (for asserting the bearer header on `/me`).
final class CapturedRequest {
  /// Wraps a captured [http.Request].
  CapturedRequest(this.request);

  /// The raw captured request.
  final http.Request request;
}

/// The pieces a test needs to drive and inspect the Auth slice.
final class AuthHarness {
  /// Creates a harness over its [container], [store], and [captured] list.
  AuthHarness({
    required this.container,
    required this.store,
    required this.captured,
  });

  /// The Riverpod container backing the overridden providers.
  final ProviderContainer container;

  /// The in-memory token store the session controller reads/writes.
  final InMemoryTokenStore store;

  /// Every request the [MockClient] saw, in order.
  final List<CapturedRequest> captured;

  /// The list of `ProviderScope` overrides to feed a `ProviderScope` widget in
  /// a widget test (so the widget tree shares this harness's wiring).
  List<Override> get overrides => _overrides;

  late final List<Override> _overrides;

  /// Disposes the container (call in `addTearDown`).
  void dispose() => container.dispose();
}

/// Builds an [AuthHarness]. The [handler] decides each canned response (or
/// throws to simulate a transport failure). Optionally seed a persisted
/// [seedToken] to exercise the boot-time restore path.
AuthHarness buildAuthHarness(
  Future<http.Response> Function(http.Request request) handler, {
  String? seedToken,
}) {
  final captured = <CapturedRequest>[];
  final store = InMemoryTokenStore(seedToken);

  final client = MockClient((request) async {
    captured.add(CapturedRequest(request));
    return handler(request);
  });

  final overrides = <Override>[
    tokenStoreProvider.overrideWithValue(store),
    apiTransportProvider.overrideWith(
      (ref) => ApiTransport(
        baseUri: Uri.parse('https://api.test.example/'),
        httpClient: client,
        tokenProvider: store.read,
      ),
    ),
    authApiProvider.overrideWith(
      (ref) => AuthApi(ref.watch(apiTransportProvider)),
    ),
  ];

  final container = ProviderContainer(overrides: overrides);
  final harness = AuthHarness(
    container: container,
    store: store,
    captured: captured,
  );
  harness._overrides = overrides;
  return harness;
}

/// A `200 OK` `/me` response for [user].
http.Response okMe(AuthenticatedUserDto user) => http.Response(
  jsonEncode(MeResponseDto(user: user).toJson()),
  200,
  headers: const {'content-type': 'application/json'},
);

/// A non-2xx response carrying the server's versioned error envelope.
http.Response errorEnvelope(int status, String code, String message) =>
    http.Response(
      jsonEncode({'schema_version': 1, 'code': code, 'message': message}),
      status,
      headers: const {'content-type': 'application/json'},
    );

/// A convenient sample principal.
const AuthenticatedUserDto sampleUser = AuthenticatedUserDto(
  userId: 'u-1',
  role: 'user',
  status: 'active',
  email: 'a@example.com',
);
