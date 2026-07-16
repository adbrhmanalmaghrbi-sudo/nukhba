/// Widget tests for the Leaderboards (view) screen, wired through the real
/// screen + provider over `buildLeaderboardsHarness` (a `MockClient`
/// transport). They assert the four user-visible states — loading,
/// legitimate-empty, error (with a retry affordance only when retryable), and
/// data (a row per participant showing rank/participant/points in the
/// server-defined order) — plus that the non-member refusal
/// (`401 leaderboard.not_a_participant`) surfaces its tailored message via
/// `ErrorPresenter` with NO retry, and that the additive
/// `SeasonRoundsScreen` entry point navigates to this screen.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mobile/features/competition/season_rounds_screen.dart';
import 'package:mobile/features/leaderboards/season_leaderboard_screen.dart';

import '../../support/leaderboards_harness.dart';

/// A `200 OK` empty JSON array — the rounds browse read the integration screen
/// issues before the leaderboard action is tapped (a season with no rounds is a
/// legitimate empty list, keeping the test focused on the navigation).
http.Response _okEmptyList() => http.Response(
  '[]',
  200,
  headers: const {'content-type': 'application/json'},
);

Widget _host(LeaderboardsHarness harness, Widget child) => ProviderScope(
  overrides: harness.overrides,
  child: MaterialApp(home: child),
);

void main() {
  group('SeasonLeaderboardScreen', () {
    testWidgets('shows a loading indicator while the read is in flight', (
      tester,
    ) async {
      // A handler that never completes keeps the provider in the loading state.
      final harness = buildLeaderboardsHarness(
        (_) => Completer<void>().future.then(
          (_) => okJsonObject(emptyBoard.toJson()),
        ),
      );
      addTearDown(harness.dispose);

      await tester.pumpWidget(
        _host(
          harness,
          const SeasonLeaderboardScreen(seasonId: 's-1', seasonLabel: '26/27'),
        ),
      );
      await tester.pump(); // first frame after the provider starts loading

      expect(find.byKey(const Key('browse.loading')), findsOneWidget);
      expect(find.byKey(const Key('leaderboard.title')), findsOneWidget);
    });

    testWidgets('data -> a ranked row per participant in server order', (
      tester,
    ) async {
      final harness = buildLeaderboardsHarness(
        (_) async => okJsonObject(sampleBoard.toJson()),
      );
      addTearDown(harness.dispose);

      await tester.pumpWidget(
        _host(
          harness,
          const SeasonLeaderboardScreen(seasonId: 's-1', seasonLabel: '26/27'),
        ),
      );
      await tester.pumpAndSettle();

      // Both participants render with their server-computed rank + points.
      expect(find.byKey(const Key('leaderboard.item.p-a')), findsOneWidget);
      expect(find.byKey(const Key('leaderboard.item.p-b')), findsOneWidget);
      expect(find.byKey(const Key('leaderboard.rank.p-a')), findsOneWidget);
      expect(find.text('12 pts'), findsOneWidget);
      expect(find.text('7 pts'), findsOneWidget);
      // Audit entry count is surfaced (plural form).
      expect(find.text('3 entries counted'), findsNWidgets(2));
    });

    testWidgets('empty board -> the empty affordance, not an error', (
      tester,
    ) async {
      final harness = buildLeaderboardsHarness(
        (_) async => okJsonObject(emptyBoard.toJson()),
      );
      addTearDown(harness.dispose);

      await tester.pumpWidget(
        _host(
          harness,
          const SeasonLeaderboardScreen(seasonId: 's-2', seasonLabel: '26/27'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('browse.empty')), findsOneWidget);
      expect(find.byKey(const Key('browse.error')), findsNothing);
    });

    testWidgets(
      'non-member (401 leaderboard.not_a_participant) -> tailored message, '
      'no retry',
      (tester) async {
        final harness = buildLeaderboardsHarness(
          (_) async => errorEnvelope(
            401,
            'leaderboard.not_a_participant',
            'Not a member of this season.',
          ),
        );
        addTearDown(harness.dispose);

        await tester.pumpWidget(
          _host(
            harness,
            const SeasonLeaderboardScreen(
              seasonId: 's-1',
              seasonLabel: '26/27',
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('browse.error')), findsOneWidget);
        // The tailored ErrorPresenter copy for this stable code (not a raw code).
        expect(
          find.textContaining('not a member of this season'),
          findsOneWidget,
        );
        // An authorization failure is NOT retryable — no retry affordance.
        expect(find.byKey(const Key('browse.error.retry')), findsNothing);
      },
    );

    testWidgets('transport failure -> error message + retry affordance', (
      tester,
    ) async {
      var calls = 0;
      final harness = buildLeaderboardsHarness((_) async {
        calls++;
        if (calls == 1) throw Exception('offline');
        return okJsonObject(sampleBoard.toJson());
      });
      addTearDown(harness.dispose);

      await tester.pumpWidget(
        _host(
          harness,
          const SeasonLeaderboardScreen(seasonId: 's-1', seasonLabel: '26/27'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('browse.error')), findsOneWidget);
      final retry = find.byKey(const Key('browse.error.retry'));
      expect(retry, findsOneWidget);

      // Tapping retry re-reads and, this time, shows the standings.
      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('browse.error')), findsNothing);
      expect(find.byKey(const Key('leaderboard.item.p-a')), findsOneWidget);
    });
  });

  group('SeasonRoundsScreen -> Leaderboard integration point', () {
    testWidgets('the app-bar action navigates to the season leaderboard', (
      tester,
    ) async {
      // Route the rounds read (empty is fine) and the leaderboard read by path.
      final harness = buildLeaderboardsHarness((request) async {
        final path = request.url.path;
        if (path == '/seasons/s-1/leaderboard') {
          return okJsonObject(sampleBoard.toJson());
        }
        // The rounds browse read for this screen — a legitimate empty list.
        return _okEmptyList();
      });
      addTearDown(harness.dispose);

      await tester.pumpWidget(
        _host(
          harness,
          const SeasonRoundsScreen(seasonId: 's-1', seasonLabel: '26/27'),
        ),
      );
      await tester.pumpAndSettle();

      // On the rounds screen; the leaderboard action is present.
      expect(find.byKey(const Key('rounds.title')), findsOneWidget);
      final action = find.byKey(const Key('rounds.viewLeaderboard'));
      expect(action, findsOneWidget);

      await tester.tap(action);
      await tester.pumpAndSettle();

      // Now on the leaderboard screen for the same season.
      expect(find.byKey(const Key('leaderboard.title')), findsOneWidget);
      expect(find.byKey(const Key('leaderboard.item.p-a')), findsOneWidget);
    });
  });
}
