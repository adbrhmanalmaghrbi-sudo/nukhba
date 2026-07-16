/// Unit tests for [PredictionController] — the submit/amend notifier that owns
/// the [SubmissionState] lifecycle for one round.
///
/// Each test drives the REAL controller over [buildPredictionHarness] (a
/// `MockClient` transport + in-memory token store — the genuine `api_client`
/// end-to-end, only the socket faked), asserting the resulting
/// [SubmissionState] and, where relevant, the exact outbound request the
/// controller issued and the read-invalidation side effect on success.
///
/// The scenarios mirror the six §4-mandated controller cases, verified against
/// the real `PredictionApi.submitPrediction` contract (`POST
/// /rounds/{id}/predictions`, body = `SubmitPredictionCommandDto`, returns a
/// `PredictionDto`; amending is the SAME call — one row per `(participant,
/// round)`, Axiom 4) and the exact `apps/server` status→code map read on disk:
///   * incomplete/malformed forecast -> `400 prediction.incomplete_forecast`
///     -> `ErrorKind.validation`;
///   * locked round                  -> `409 prediction.round_not_open`
///     -> `ErrorKind.invariant`;
///   * not a participant             -> `409 prediction.not_a_participant`
///     -> `ErrorKind.invariant`;
///   * unauthorized                  -> `401` -> `ErrorKind.authorization`;
///   * network/`503`                 -> `ErrorKind.transient` (retryable).
library;

import 'dart:async';
import 'dart:convert';

import 'package:contracts/contracts.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/features/prediction/prediction_controller.dart';
import 'package:mobile/features/prediction/prediction_providers.dart';
import 'package:mobile/features/prediction/prediction_submission.dart';
import 'package:shared/shared.dart';

import '../../support/prediction_harness.dart';

/// The scorelines a well-formed submit for [openRound]'s two fixtures carries.
const List<FixtureScoreDto> _validScores = <FixtureScoreDto>[
  FixtureScoreDto(fixtureId: 'f-a', homeGoals: 2, awayGoals: 1),
  FixtureScoreDto(fixtureId: 'f-b', homeGoals: 0, awayGoals: 0),
];

/// Reads the current [SubmissionState] for [openRound] from the container.
SubmissionState _stateOf(PredictionHarness harness) =>
    harness.container.read(predictionControllerProvider(openRound.id));

/// The submit notifier for [openRound].
PredictionController _controller(PredictionHarness harness) =>
    harness.container.read(predictionControllerProvider(openRound.id).notifier);

void main() {
  group('PredictionController — initial state', () {
    test('starts SubmissionIdle (form editable, nothing in flight)', () {
      final harness = buildPredictionHarness(
        (_) async => okJsonObject(storedPrediction.toJson()),
      );
      addTearDown(harness.dispose);

      expect(_stateOf(harness), const SubmissionIdle());
      expect(
        harness.captured,
        isEmpty,
        reason: 'building the controller must not issue any request',
      );
    });
  });

  group('PredictionController.submit — success', () {
    test(
      'a valid submit -> InFlight then Succeeded carrying the stored DTO, '
      'sending exactly the command body to POST /rounds/{id}/predictions',
      () async {
        final harness = buildPredictionHarness(
          (_) async => okJsonObject(storedPrediction.toJson()),
        );
        addTearDown(harness.dispose);

        await _controller(harness).submit(_validScores);

        final state = _stateOf(harness);
        expect(state, isA<SubmissionSucceeded>());
        expect((state as SubmissionSucceeded).prediction, storedPrediction);

        // Exactly one outbound request, and it is the submit POST.
        expect(harness.captured, hasLength(1));
        final request = harness.captured.single.request;
        expect(request.method, 'POST');
        expect(request.url.path, '/rounds/${openRound.id}/predictions');
        // The bearer token is attached exactly as production does.
        expect(request.headers['authorization'], 'Bearer predict-jwt');
        // The body is the SubmitPredictionCommandDto shape — the scorelines only,
        // NO participant id / points ever sent (Axioms 2/5).
        final decodedBody = (jsonDecode(request.body) as Map)
            .cast<String, Object?>();
        final sent = SubmitPredictionCommandDto.fromJson(decodedBody);
        expect(sent.fixtureScores, _validScores);
        // Defensive: the wire body carries no participant id or points key.
        expect(decodedBody.containsKey('participant_id'), isFalse);
        expect(decodedBody.containsKey('points'), isFalse);
      },
    );

    test(
      'success invalidates myPredictionProvider so the read refreshes',
      () async {
        var predictionReads = 0;
        final harness = buildPredictionHarness((request) async {
          if (request.method == 'GET' &&
              request.url.path == '/rounds/${openRound.id}/predictions') {
            predictionReads++;
            return okJsonObject(storedPrediction.toJson());
          }
          // POST submit
          return okJsonObject(storedPrediction.toJson());
        });
        addTearDown(harness.dispose);

        // Prime the read once.
        await harness.container.read(myPredictionProvider(openRound.id).future);
        expect(predictionReads, 1);

        await _controller(harness).submit(_validScores);
        expect(_stateOf(harness), isA<SubmissionSucceeded>());

        // The invalidation forces the next read to re-fetch.
        await harness.container.read(myPredictionProvider(openRound.id).future);
        expect(
          predictionReads,
          2,
          reason: 'a successful submit must invalidate the my-prediction read',
        );
      },
    );
  });

  group('PredictionController.submit — amend an existing prediction', () {
    test('amending is the SAME submit call (contract allows it) and yields '
        'Succeeded with the amended DTO', () async {
      // The contract's submitPrediction is the single upsert path — there is no
      // separate edit endpoint (one row per (participant, round), Axiom 4).
      const amended = PredictionDto(
        id: 'p-1',
        participantId: 'part-1',
        roundId: 'r-1',
        submittedAt: '2026-08-02T09:30:00.000Z',
        fixtureScores: <FixtureScoreDto>[
          FixtureScoreDto(fixtureId: 'f-a', homeGoals: 3, awayGoals: 2),
          FixtureScoreDto(fixtureId: 'f-b', homeGoals: 1, awayGoals: 1),
        ],
      );
      final harness = buildPredictionHarness(
        (_) async => okJsonObject(amended.toJson()),
      );
      addTearDown(harness.dispose);

      const newScores = <FixtureScoreDto>[
        FixtureScoreDto(fixtureId: 'f-a', homeGoals: 3, awayGoals: 2),
        FixtureScoreDto(fixtureId: 'f-b', homeGoals: 1, awayGoals: 1),
      ];
      await _controller(harness).submit(newScores);

      final state = _stateOf(harness);
      expect(state, isA<SubmissionSucceeded>());
      expect((state as SubmissionSucceeded).prediction, amended);
      // Only one write — an amend is not two calls.
      expect(
        harness.captured.where((c) => c.request.method == 'POST'),
        hasLength(1),
      );
    });
  });

  group('PredictionController.submit — validation failure', () {
    test(
      'an empty forecast is refused locally as validation, no network call',
      () async {
        final harness = buildPredictionHarness(
          (_) async => okJsonObject(storedPrediction.toJson()),
        );
        addTearDown(harness.dispose);

        await _controller(harness).submit(const <FixtureScoreDto>[]);

        final state = _stateOf(harness);
        expect(state, isA<SubmissionFailed>());
        final error = (state as SubmissionFailed).error;
        expect(error.kind, ErrorKind.validation);
        expect(error.code, predictionEmptySubmissionCode);
        expect(
          harness.captured,
          isEmpty,
          reason: 'an empty submit must not touch the network',
        );
      },
    );

    test('a server-rejected incomplete forecast (400) -> Failed(validation) '
        'carrying the server code', () async {
      final harness = buildPredictionHarness(
        (_) async => errorEnvelope(
          400,
          'prediction.incomplete_forecast',
          'A prediction must cover every fixture in the round.',
        ),
      );
      addTearDown(harness.dispose);

      await _controller(harness).submit(_validScores);

      final state = _stateOf(harness);
      expect(state, isA<SubmissionFailed>());
      final error = (state as SubmissionFailed).error;
      expect(error.kind, ErrorKind.validation);
      expect(error.code, 'prediction.incomplete_forecast');
      expect(error.isRetryable, isFalse);
    });
  });

  group('PredictionController.submit — authorization failure (401)', () {
    test('401 -> Failed(authorization); not retryable', () async {
      final harness = buildPredictionHarness(
        (_) async => errorEnvelope(
          401,
          'auth.token_invalid',
          'Your session has expired.',
        ),
      );
      addTearDown(harness.dispose);

      await _controller(harness).submit(_validScores);

      final state = _stateOf(harness);
      expect(state, isA<SubmissionFailed>());
      final error = (state as SubmissionFailed).error;
      expect(error.kind, ErrorKind.authorization);
      expect(error.code, 'auth.token_invalid');
      expect(error.isRetryable, isFalse);
    });
  });

  group('PredictionController.submit — transient / network failure', () {
    test('a transport exception -> Failed(transient), retryable', () async {
      final harness = buildPredictionHarness(
        (_) async => throw Exception('socket reset'),
      );
      addTearDown(harness.dispose);

      await _controller(harness).submit(_validScores);

      final state = _stateOf(harness);
      expect(state, isA<SubmissionFailed>());
      final error = (state as SubmissionFailed).error;
      expect(error.kind, ErrorKind.transient);
      expect(error.isRetryable, isTrue);
    });

    test('a 503 from the server -> Failed(transient), retryable', () async {
      final harness = buildPredictionHarness(
        (_) async => errorEnvelope(
          503,
          'server.unavailable',
          'The service is temporarily unavailable.',
        ),
      );
      addTearDown(harness.dispose);

      await _controller(harness).submit(_validScores);

      final state = _stateOf(harness);
      expect(state, isA<SubmissionFailed>());
      expect((state as SubmissionFailed).error.kind, ErrorKind.transient);
      expect(state.error.isRetryable, isTrue);
    });
  });

  group('PredictionController.submit — locked round rejection (409)', () {
    test('409 round_not_open -> Failed(invariant); not retryable', () async {
      final harness = buildPredictionHarness(
        (_) async => errorEnvelope(
          409,
          'prediction.round_not_open',
          'This round is no longer open for predictions.',
        ),
      );
      addTearDown(harness.dispose);

      await _controller(harness).submit(_validScores);

      final state = _stateOf(harness);
      expect(state, isA<SubmissionFailed>());
      final error = (state as SubmissionFailed).error;
      expect(error.kind, ErrorKind.invariant);
      expect(error.code, 'prediction.round_not_open');
      expect(error.isRetryable, isFalse);
    });

    test('409 not_a_participant -> Failed(invariant)', () async {
      final harness = buildPredictionHarness(
        (_) async => errorEnvelope(
          409,
          'prediction.not_a_participant',
          'You have not joined this competition.',
        ),
      );
      addTearDown(harness.dispose);

      await _controller(harness).submit(_validScores);

      final state = _stateOf(harness);
      expect(state, isA<SubmissionFailed>());
      final error = (state as SubmissionFailed).error;
      expect(error.kind, ErrorKind.invariant);
      expect(error.code, 'prediction.not_a_participant');
    });
  });

  group('PredictionController.submit — double-submit guard', () {
    test(
      'a second submit while one is in flight is ignored (one request)',
      () async {
        // A gate the test releases only after both submit() calls have been made,
        // proving the second call is dropped while the first is InFlight.
        final gate = Completer<void>();
        final harness = buildPredictionHarness((_) async {
          await gate.future;
          return okJsonObject(storedPrediction.toJson());
        });
        addTearDown(harness.dispose);

        final controller = _controller(harness);
        final first = controller.submit(_validScores);
        // While the first is awaiting the gated response, the state is InFlight.
        expect(_stateOf(harness), const SubmissionInFlight());

        // A second overlapping submit must be a no-op.
        await controller.submit(_validScores);
        expect(
          _stateOf(harness),
          const SubmissionInFlight(),
          reason: 'the in-flight submit wins; the second is dropped',
        );

        gate.complete();
        await first;

        expect(_stateOf(harness), isA<SubmissionSucceeded>());
        expect(
          harness.captured.where((c) => c.request.method == 'POST'),
          hasLength(1),
          reason: 'only the first submit reaches the network',
        );
      },
    );
  });

  group('PredictionController.reset', () {
    test('returns Failed -> Idle so the form can be edited again', () async {
      final harness = buildPredictionHarness(
        (_) async => errorEnvelope(400, 'prediction.incomplete_forecast', 'x'),
      );
      addTearDown(harness.dispose);
      final controller = _controller(harness);

      await controller.submit(_validScores);
      expect(_stateOf(harness), isA<SubmissionFailed>());

      controller.reset();
      expect(_stateOf(harness), const SubmissionIdle());
    });
  });
}
