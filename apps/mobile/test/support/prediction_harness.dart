/// Test harness for the Prediction (submit) slice.
///
/// Mirrors `competition_harness.dart`: it builds a `ProviderScope` whose
/// networking is served entirely by a `package:http/testing.dart` [MockClient]
/// (no live socket), wiring the shared `apiTransportProvider` over that client so
/// the real `predictionApiProvider` (the submit controller + `myPredictionProvider`)
/// AND the real `competitionApiProvider` (the reused `roundDetailProvider` /
/// `roundFixturesProvider` the screen composes) exercise the genuine `api_client`
/// end-to-end — only the socket is faked. The token store is a seedable in-memory
/// fake so the transport still attaches a bearer token exactly as production does.
///
/// A test supplies a [handler] that returns a canned response per request (or
/// throws to simulate a transport failure). Because the Prediction screen issues
/// several distinct reads/writes (`GET /rounds/{id}`, `GET /rounds/{id}/fixtures`,
/// `GET /rounds/{id}/predictions`, `POST /rounds/{id}/predictions`), the handler
/// is expected to branch on `request.method` + `request.url.path`. Response
/// builders ([okJsonList]/[okJsonObject]/[errorEnvelope]) and DTO fixtures are
/// provided.
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

/// One captured outbound request (for asserting method + path + body).
final class CapturedRequest {
  /// Wraps a captured [http.Request].
  CapturedRequest(this.request);

  /// The raw captured request.
  final http.Request request;
}

/// The pieces a test needs to drive and inspect the Prediction slice.
final class PredictionHarness {
  /// Creates a harness over its [container] and [captured] list.
  PredictionHarness({required this.container, required this.captured});

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

/// Builds a [PredictionHarness]. The [handler] decides each canned response (or
/// throws to simulate a transport failure).
PredictionHarness buildPredictionHarness(
  Future<http.Response> Function(http.Request request) handler,
) {
  final captured = <CapturedRequest>[];
  final client = MockClient((request) async {
    captured.add(CapturedRequest(request));
    return handler(request);
  });

  final overrides = <Override>[
    // A fixed token store so the transport attaches a bearer token like prod.
    tokenStoreProvider.overrideWithValue(InMemoryTokenStore('predict-jwt')),
    apiTransportProvider.overrideWith(
      (ref) => ApiTransport(
        baseUri: Uri.parse('https://api.test.example/'),
        httpClient: client,
        tokenProvider: ref.watch(tokenStoreProvider).read,
      ),
    ),
    // The real Prediction + Competition clients over the faked transport (the
    // providers/controller/screen under test are NOT overridden).
    predictionApiProvider.overrideWith(
      (ref) => PredictionApi(ref.watch(apiTransportProvider)),
    ),
    competitionApiProvider.overrideWith(
      (ref) => CompetitionApi(ref.watch(apiTransportProvider)),
    ),
  ];

  final container = ProviderContainer(overrides: overrides);
  final harness = PredictionHarness(container: container, captured: captured);
  harness._overrides = overrides;
  return harness;
}

/// A `200 OK` JSON-array response (a list read).
http.Response okJsonList(List<Object?> elements) => http.Response(
  jsonEncode(elements),
  200,
  headers: const {'content-type': 'application/json'},
);

/// A `200 OK` JSON-object response (a single-item read or a submit result).
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
// DTO fixtures (the exact wire shapes the prediction/round routes return).
// ---------------------------------------------------------------------------

/// An OPEN round (predictions allowed).
const RoundDto openRound = RoundDto(
  id: 'r-1',
  seasonId: 's-1',
  sequence: 1,
  predictionDeadline: '2026-08-15T18:00:00.000Z',
  status: 'open',
  rulesetVersion: 3,
);

/// A LOCKED round (predictions closed).
const RoundDto lockedRound = RoundDto(
  id: 'r-1',
  seasonId: 's-1',
  sequence: 1,
  predictionDeadline: '2026-08-15T18:00:00.000Z',
  status: 'locked',
  rulesetVersion: 3,
);

/// Two fixtures of [openRound], in display order.
const RoundFixtureDto fixtureA = RoundFixtureDto(
  roundId: 'r-1',
  fixtureId: 'f-a',
  displayOrder: 0,
);

/// The second fixture of [openRound].
const RoundFixtureDto fixtureB = RoundFixtureDto(
  roundId: 'r-1',
  fixtureId: 'f-b',
  displayOrder: 1,
);

/// A stored prediction for [openRound] covering both fixtures.
const PredictionDto storedPrediction = PredictionDto(
  id: 'p-1',
  participantId: 'part-1',
  roundId: 'r-1',
  submittedAt: '2026-08-01T10:00:00.000Z',
  fixtureScores: <FixtureScoreDto>[
    FixtureScoreDto(fixtureId: 'f-a', homeGoals: 2, awayGoals: 1),
    FixtureScoreDto(fixtureId: 'f-b', homeGoals: 0, awayGoals: 0),
  ],
);
