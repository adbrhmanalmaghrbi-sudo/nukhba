/// Test harness for the Leaderboards (view) slice.
///
/// Mirrors `competition_harness.dart`/`auth_harness.dart`: it builds a
/// `ProviderScope` whose networking is served entirely by a
/// `package:http/testing.dart` [MockClient] (no live socket), wiring the shared
/// `apiTransportProvider` over that client so the real `leaderboardsApiProvider`
/// (and the `seasonLeaderboardProvider` watching it) exercise the genuine
/// `api_client` `LeaderboardsApi` end-to-end — only the socket is faked. The
/// token store is a seedable in-memory fake so the transport still attaches a
/// bearer token exactly as production does.
///
/// A test supplies a [handler] that returns a canned response per request (or
/// throws to simulate a transport failure). Helper response builders
/// ([okJsonObject]/[errorEnvelope]) and DTO fixtures are provided so the
/// success / legitimate-empty / non-member / transient cases are easy to script.
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

/// One captured outbound request (for asserting method + path).
final class CapturedRequest {
  /// Wraps a captured [http.Request].
  CapturedRequest(this.request);

  /// The raw captured request.
  final http.Request request;
}

/// The pieces a test needs to drive and inspect the Leaderboards slice.
final class LeaderboardsHarness {
  /// Creates a harness over its [container] and [captured] list.
  LeaderboardsHarness({required this.container, required this.captured});

  /// The Riverpod container backing the overridden providers.
  final ProviderContainer container;

  /// Every request the [MockClient] saw, in order.
  final List<CapturedRequest> captured;

  /// `ProviderScope` overrides for widget tests.
  List<Override> get overrides => _overrides;

  late final List<Override> _overrides;

  /// Disposes the container (call in `addTearDown`).
  void dispose() => container.dispose();
}

/// Builds a [LeaderboardsHarness]. The [handler] decides each canned response
/// (or throws to simulate a transport failure).
LeaderboardsHarness buildLeaderboardsHarness(
  Future<http.Response> Function(http.Request request) handler,
) {
  final captured = <CapturedRequest>[];
  final client = MockClient((request) async {
    captured.add(CapturedRequest(request));
    return handler(request);
  });

  final overrides = <Override>[
    // A fixed token store so the transport attaches a bearer token like prod.
    tokenStoreProvider.overrideWithValue(InMemoryTokenStore('board-jwt')),
    apiTransportProvider.overrideWith(
      (ref) => ApiTransport(
        baseUri: Uri.parse('https://api.test.example/'),
        httpClient: client,
        tokenProvider: ref.watch(tokenStoreProvider).read,
      ),
    ),
    // The real LeaderboardsApi over the faked transport (the leaderboard
    // provider itself is what is under test — not overridden).
    leaderboardsApiProvider.overrideWith(
      (ref) => LeaderboardsApi(ref.watch(apiTransportProvider)),
    ),
  ];

  final container = ProviderContainer(overrides: overrides);
  final harness = LeaderboardsHarness(container: container, captured: captured);
  harness._overrides = overrides;
  return harness;
}

/// A `200 OK` JSON-object response (the single leaderboard read).
http.Response okJsonObject(Map<String, Object?> object) => http.Response(
  jsonEncode(object),
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

// ---------------------------------------------------------------------------
// DTO fixtures (the exact wire shapes the leaderboard route returns).
// ---------------------------------------------------------------------------

/// A sample two-entry season leaderboard in server display order (rank 1 then
/// rank 2). Totals are server-produced; the client never recomputes them.
const SeasonLeaderboardDto sampleBoard = SeasonLeaderboardDto(
  seasonId: 's-1',
  entries: <LeaderboardEntryDto>[
    LeaderboardEntryDto(
      rank: 1,
      participantId: 'p-a',
      totalPoints: 12,
      entryCount: 3,
    ),
    LeaderboardEntryDto(
      rank: 2,
      participantId: 'p-b',
      totalPoints: 7,
      entryCount: 3,
    ),
  ],
);

/// A sample leaderboard for a season with no participants (a legitimate empty
/// board, never an error).
const SeasonLeaderboardDto emptyBoard = SeasonLeaderboardDto(
  seasonId: 's-2',
  entries: <LeaderboardEntryDto>[],
);
