/// Widget tests for [PredictionScreen], wired through the real screen +
/// providers + submit controller over [buildPredictionHarness] (a `MockClient`
/// transport). They assert the user-visible submit surface at the same depth as
/// `competition_browse_widgets_test.dart`:
///   * the form renders one score input per fixture for an OPEN round;
///   * a not-open (locked) round shows the read-only "closed" notice and NO
///     submit affordance;
///   * the submit button is disabled while a submit is `InFlight` (spinner up);
///   * an existing prediction surfaces the "already submitted" banner and
///     pre-fills the inputs;
///   * a failed submit renders the typed error via `ErrorPresenter` (never a
///     raw code) and keeps the form editable.
///
/// Networking is served entirely by the harness handler branching on
/// `request.method` + `request.url.path` (the screen issues `GET /rounds/{id}`,
/// `GET /rounds/{id}/fixtures`, `GET /rounds/{id}/predictions`, and — on submit
/// — `POST /rounds/{id}/predictions`). Only the socket is faked; the real
/// `api_client` runs end-to-end.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mobile/features/prediction/prediction_screen.dart';

import '../../support/prediction_harness.dart';

Widget _host(PredictionHarness harness, Widget child) => ProviderScope(
  overrides: harness.overrides,
  child: MaterialApp(home: child),
);

/// A handler for an OPEN round with two fixtures and no existing prediction
/// (the GET /predictions "mine" read returns 404 not_found). [onSubmit] decides
/// the POST response.
Future<http.Response> Function(http.Request) _openRoundHandler({
  required Future<http.Response> Function() onSubmit,
  bool alreadySubmitted = false,
}) {
  return (request) async {
    final path = request.url.path;
    if (request.method == 'GET' && path == '/rounds/r-1') {
      return okJsonObject(openRound.toJson());
    }
    if (request.method == 'GET' && path == '/rounds/r-1/fixtures') {
      return okJsonList([fixtureA.toJson(), fixtureB.toJson()]);
    }
    if (request.method == 'GET' && path == '/rounds/r-1/predictions') {
      return alreadySubmitted
          ? okJsonObject(storedPrediction.toJson())
          : errorEnvelope(
              404,
              'prediction.not_found',
              'You have not predicted this round yet.',
            );
    }
    if (request.method == 'POST' && path == '/rounds/r-1/predictions') {
      return onSubmit();
    }
    return okJsonList(<Object>[]);
  };
}

void main() {
  group('PredictionScreen — open round form', () {
    testWidgets('renders the round header + one score input per fixture', (
      tester,
    ) async {
      final harness = buildPredictionHarness(
        _openRoundHandler(
          onSubmit: () async => okJsonObject(storedPrediction.toJson()),
        ),
      );
      addTearDown(harness.dispose);

      await tester.pumpWidget(
        _host(harness, const PredictionScreen(roundId: 'r-1')),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('prediction.roundHeader')), findsOneWidget);
      expect(find.byKey(const Key('prediction.form')), findsOneWidget);
      // One input pair per fixture, in display order.
      expect(find.byKey(const Key('prediction.home.f-a')), findsOneWidget);
      expect(find.byKey(const Key('prediction.away.f-a')), findsOneWidget);
      expect(find.byKey(const Key('prediction.home.f-b')), findsOneWidget);
      expect(find.byKey(const Key('prediction.away.f-b')), findsOneWidget);
      expect(find.byKey(const Key('prediction.submit')), findsOneWidget);
      // A fresh, unsubmitted round shows neither the already-submitted banner
      // nor an error.
      expect(
        find.byKey(const Key('prediction.alreadySubmitted')),
        findsNothing,
      );
      expect(find.byKey(const Key('prediction.errorBanner')), findsNothing);
      // The closed notice must NOT appear for an open round.
      expect(find.byKey(const Key('prediction.closed')), findsNothing);
    });

    testWidgets(
      'submit is disabled until every fixture has a valid goal count',
      (tester) async {
        final harness = buildPredictionHarness(
          _openRoundHandler(
            onSubmit: () async => okJsonObject(storedPrediction.toJson()),
          ),
        );
        addTearDown(harness.dispose);

        await tester.pumpWidget(
          _host(harness, const PredictionScreen(roundId: 'r-1')),
        );
        await tester.pumpAndSettle();

        FilledButton submitButton() => tester.widget<FilledButton>(
          find.byKey(const Key('prediction.submit')),
        );

        // Nothing entered yet -> disabled.
        expect(submitButton().onPressed, isNull);

        // Fill only one fixture fully -> still disabled (incomplete locally).
        await tester.enterText(
          find.byKey(const Key('prediction.home.f-a')),
          '2',
        );
        await tester.enterText(
          find.byKey(const Key('prediction.away.f-a')),
          '1',
        );
        await tester.pump();
        expect(submitButton().onPressed, isNull);

        // Complete the second fixture -> now enabled.
        await tester.enterText(
          find.byKey(const Key('prediction.home.f-b')),
          '0',
        );
        await tester.enterText(
          find.byKey(const Key('prediction.away.f-b')),
          '0',
        );
        await tester.pump();
        expect(submitButton().onPressed, isNotNull);
      },
    );
  });

  group('PredictionScreen — closed round', () {
    testWidgets('a locked round shows the closed notice and no submit form', (
      tester,
    ) async {
      final harness = buildPredictionHarness((request) async {
        if (request.method == 'GET' && request.url.path == '/rounds/r-1') {
          return okJsonObject(lockedRound.toJson());
        }
        return okJsonList(<Object>[]);
      });
      addTearDown(harness.dispose);

      await tester.pumpWidget(
        _host(harness, const PredictionScreen(roundId: 'r-1')),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('prediction.roundHeader')), findsOneWidget);
      expect(find.byKey(const Key('prediction.closed')), findsOneWidget);
      expect(
        find.byKey(const Key('prediction.closed.message')),
        findsOneWidget,
      );
      // No form / submit affordance once the round has left "open".
      expect(find.byKey(const Key('prediction.form')), findsNothing);
      expect(find.byKey(const Key('prediction.submit')), findsNothing);
    });
  });

  group('PredictionScreen — in-flight submit', () {
    testWidgets('the submit button is disabled and shows a spinner while the '
        'POST is in flight', (tester) async {
      // A gated POST so the submit stays InFlight until the test releases it.
      final gate = Completer<void>();
      final harness = buildPredictionHarness(
        _openRoundHandler(
          onSubmit: () async {
            await gate.future;
            return okJsonObject(storedPrediction.toJson());
          },
        ),
      );
      addTearDown(harness.dispose);

      await tester.pumpWidget(
        _host(harness, const PredictionScreen(roundId: 'r-1')),
      );
      await tester.pumpAndSettle();

      // Fill a valid forecast and tap submit.
      await tester.enterText(find.byKey(const Key('prediction.home.f-a')), '2');
      await tester.enterText(find.byKey(const Key('prediction.away.f-a')), '1');
      await tester.enterText(find.byKey(const Key('prediction.home.f-b')), '0');
      await tester.enterText(find.byKey(const Key('prediction.away.f-b')), '0');
      await tester.pump();

      await tester.tap(find.byKey(const Key('prediction.submit')));
      await tester.pump(); // let the controller move to InFlight

      // While in flight: spinner shown, button disabled.
      expect(
        find.byKey(const Key('prediction.submit.spinner')),
        findsOneWidget,
      );
      final button = tester.widget<FilledButton>(
        find.byKey(const Key('prediction.submit')),
      );
      expect(button.onPressed, isNull);

      // Release the response; the submit succeeds.
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('prediction.submit.spinner')), findsNothing);
      expect(find.byKey(const Key('prediction.success')), findsOneWidget);
    });
  });

  group('PredictionScreen — already submitted', () {
    testWidgets('an existing prediction shows the already-submitted banner and '
        'pre-fills the inputs', (tester) async {
      final harness = buildPredictionHarness(
        _openRoundHandler(
          alreadySubmitted: true,
          onSubmit: () async => okJsonObject(storedPrediction.toJson()),
        ),
      );
      addTearDown(harness.dispose);

      await tester.pumpWidget(
        _host(harness, const PredictionScreen(roundId: 'r-1')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('prediction.alreadySubmitted')),
        findsOneWidget,
      );
      // The stored scoreline pre-fills each input (f-a: 2-1, f-b: 0-0).
      final homeA = tester.widget<TextField>(
        find.descendant(
          of: find.byKey(const Key('prediction.home.f-a')),
          matching: find.byType(TextField),
        ),
      );
      expect(homeA.controller!.text, '2');
      final awayA = tester.widget<TextField>(
        find.descendant(
          of: find.byKey(const Key('prediction.away.f-a')),
          matching: find.byType(TextField),
        ),
      );
      expect(awayA.controller!.text, '1');
    });
  });

  group('PredictionScreen — submit failure via ErrorPresenter', () {
    testWidgets('a rejected submit renders the error banner and keeps the form '
        'editable', (tester) async {
      final harness = buildPredictionHarness(
        _openRoundHandler(
          onSubmit: () async => errorEnvelope(
            409,
            'prediction.round_not_open',
            'This round is no longer open for predictions.',
          ),
        ),
      );
      addTearDown(harness.dispose);

      await tester.pumpWidget(
        _host(harness, const PredictionScreen(roundId: 'r-1')),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('prediction.home.f-a')), '2');
      await tester.enterText(find.byKey(const Key('prediction.away.f-a')), '1');
      await tester.enterText(find.byKey(const Key('prediction.home.f-b')), '0');
      await tester.enterText(find.byKey(const Key('prediction.away.f-b')), '0');
      await tester.pump();

      await tester.tap(find.byKey(const Key('prediction.submit')));
      await tester.pumpAndSettle();

      // The typed failure is shown through ErrorPresenter — the invariant
      // fallback copy carries the server message (never the raw code).
      expect(find.byKey(const Key('prediction.errorBanner')), findsOneWidget);
      expect(
        find.text('This round is no longer open for predictions.'),
        findsOneWidget,
      );
      // The form stays editable after a failure (inputs still present, submit
      // re-enabled since a valid forecast is entered).
      expect(find.byKey(const Key('prediction.form')), findsOneWidget);
      final button = tester.widget<FilledButton>(
        find.byKey(const Key('prediction.submit')),
      );
      expect(button.onPressed, isNotNull);
    });

    testWidgets('a transient submit failure renders the connection message', (
      tester,
    ) async {
      final harness = buildPredictionHarness(
        _openRoundHandler(onSubmit: () async => throw Exception('offline')),
      );
      addTearDown(harness.dispose);

      await tester.pumpWidget(
        _host(harness, const PredictionScreen(roundId: 'r-1')),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('prediction.home.f-a')), '2');
      await tester.enterText(find.byKey(const Key('prediction.away.f-a')), '1');
      await tester.enterText(find.byKey(const Key('prediction.home.f-b')), '0');
      await tester.enterText(find.byKey(const Key('prediction.away.f-b')), '0');
      await tester.pump();

      await tester.tap(find.byKey(const Key('prediction.submit')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('prediction.errorBanner')), findsOneWidget);
      expect(
        find.textContaining('could not reach the server', findRichText: false),
        findsOneWidget,
      );
    });
  });
}
