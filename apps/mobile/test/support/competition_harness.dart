/// Test harness for the Competition (browse) slice.
///
/// Mirrors `auth_harness.dart`: it builds a `ProviderScope` whose networking is
/// served entirely by a `package:http/testing.dart` [MockClient] (no live
/// socket), wiring the shared `apiTransportProvider` over that client so the
/// real `competitionApiProvider` (and the browse providers watching it) exercise
/// the genuine `api_client` `CompetitionApi` end-to-end — only the socket is
/// faked. The token store is a seedable in-memory fake so the transport still
/// attaches a bearer token exactly as production does.
///
/// A test supplies a [handler] that returns a canned response per request (or
/// throws to simulate a transport failure). Helper response builders
/// ([okJsonList]/[okJsonObject]/[errorEnvelope]) and DTO fixtures are provided
/// so each browse level's success / legitimate-empty / error / not-found cases
/// are easy to script.
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

/// The pieces a test needs to drive and inspect the Competition browse slice.
final class CompetitionHarness {
  /// Creates a harness over its [container] and [captured] list.
  CompetitionHarness({required this.container, required this.captured});

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

/// Builds a [CompetitionHarness]. The [handler] decides each canned response (or
/// throws to simulate a transport failure).
CompetitionHarness buildCompetitionHarness(
  Future<http.Response> Function(http.Request request) handler,
) {
  final captured = <CapturedRequest>[];
  final client = MockClient((request) async {
    captured.add(CapturedRequest(request));
    return handler(request);
  });

  final overrides = <Override>[
    // A fixed token store so the transport attaches a bearer token like prod.
    tokenStoreProvider.overrideWithValue(InMemoryTokenStore('browse-jwt')),
    apiTransportProvider.overrideWith(
      (ref) => ApiTransport(
        baseUri: Uri.parse('https://api.test.example/'),
        httpClient: client,
        tokenProvider: ref.watch(tokenStoreProvider).read,
      ),
    ),
    // The real CompetitionApi over the faked transport (no override of the
    // competition providers themselves — they are what is under test).
    competitionApiProvider.overrideWith(
      (ref) => CompetitionApi(ref.watch(apiTransportProvider)),
    ),
  ];

  final container = ProviderContainer(overrides: overrides);
  final harness = CompetitionHarness(container: container, captured: captured);
  harness._overrides = overrides;
  return harness;
}

/// A `200 OK` JSON-array response (a list read).
http.Response okJsonList(List<Object?> elements) => http.Response(
  jsonEncode(elements),
  200,
  headers: const {'content-type': 'application/json'},
);

/// A `200 OK` JSON-object response (a single-item read).
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
// DTO fixtures (the exact wire shapes the browse routes return).
// ---------------------------------------------------------------------------

/// A sample public competition.
const CompetitionDto sampleCompetition = CompetitionDto(
  id: 'c-1',
  name: 'Premier League',
  format: 'football_scoreline',
  visibility: 'public',
);

/// A second sample competition (for ordering assertions).
const CompetitionDto sampleCompetition2 = CompetitionDto(
  id: 'c-2',
  name: 'Champions League',
  format: 'football_scoreline',
  visibility: 'public',
);

/// A sample season of [sampleCompetition].
const SeasonDto sampleSeason = SeasonDto(
  id: 's-1',
  competitionId: 'c-1',
  label: '2026/27',
);

/// A sample round of [sampleSeason].
const RoundDto sampleRound = RoundDto(
  id: 'r-1',
  seasonId: 's-1',
  sequence: 1,
  predictionDeadline: '2026-08-15T18:00:00.000Z',
  status: 'open',
  rulesetVersion: 3,
);

/// A sample fixture link of [sampleRound].
const RoundFixtureDto sampleFixture = RoundFixtureDto(
  roundId: 'r-1',
  fixtureId: 'f-1',
  displayOrder: 0,
);
