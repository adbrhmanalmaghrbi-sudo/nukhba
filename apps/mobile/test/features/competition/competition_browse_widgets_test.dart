/// Widget tests for the Competition browse screens, wired through the real
/// screens + providers over `buildCompetitionHarness` (a `MockClient`
/// transport). They assert the four user-visible browse states — loading,
/// legitimate-empty, error (with a retry affordance on a transient failure),
/// and data — plus the drill-down navigation competition → seasons → rounds →
/// fixtures, and that a not-found round surfaces its "not found" message via
/// `ErrorPresenter` (never an empty list).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/features/competition/competition_list_screen.dart';
import 'package:mobile/features/competition/round_fixtures_screen.dart';

import '../../support/competition_harness.dart';

Widget _host(CompetitionHarness harness, Widget child) => ProviderScope(
  overrides: harness.overrides,
  retry: (retryCount, error) => null,
  child: MaterialApp(home: child),
);

void main() {
  group('CompetitionListScreen', () {
    testWidgets('shows a loading indicator while the read is in flight', (
      tester,
    ) async {
      // A handler that never completes keeps the provider in the loading state.
      final harness = buildCompetitionHarness(
        (_) => Completer<void>().future.then((_) => okJsonList(<Object>[])),
      );
      addTearDown(harness.dispose);

      await tester.pumpWidget(_host(harness, const CompetitionListScreen()));
      await tester.pump(); // first frame after the provider starts loading

      expect(find.byKey(const Key('browse.loading')), findsOneWidget);
    });

    testWidgets('empty catalogue -> the empty affordance, not an error', (
      tester,
    ) async {
      final harness = buildCompetitionHarness(
        (_) async => okJsonList(<Object>[]),
      );
      addTearDown(harness.dispose);

      await tester.pumpWidget(_host(harness, const CompetitionListScreen()));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('browse.empty')), findsOneWidget);
      expect(find.byKey(const Key('browse.error')), findsNothing);
    });

    testWidgets('transport failure -> error message + retry affordance', (
      tester,
    ) async {
      var calls = 0;
      final harness = buildCompetitionHarness((_) async {
        calls++;
        if (calls == 1) throw Exception('offline');
        return okJsonList([sampleCompetition.toJson()]);
      });
      addTearDown(harness.dispose);

      await tester.pumpWidget(_host(harness, const CompetitionListScreen()));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('browse.error')), findsOneWidget);
      // A transient failure is retryable, so the retry button is offered.
      final retry = find.byKey(const Key('browse.error.retry'));
      expect(retry, findsOneWidget);

      // Tapping retry re-reads and, this time, shows the data.
      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('browse.error')), findsNothing);
      expect(find.byKey(const Key('competitions.item.c-1')), findsOneWidget);
    });

    testWidgets('data -> a row per competition and drill-down to seasons', (
      tester,
    ) async {
      // Route each browse hop by path so navigation can be followed.
      final harness = buildCompetitionHarness((request) async {
        final path = request.url.path;
        if (path == '/competitions') {
          return okJsonList([sampleCompetition.toJson()]);
        }
        if (path == '/competitions/c-1/seasons') {
          return okJsonList([sampleSeason.toJson()]);
        }
        return okJsonList(<Object>[]);
      });
      addTearDown(harness.dispose);

      await tester.pumpWidget(_host(harness, const CompetitionListScreen()));
      await tester.pumpAndSettle();

      expect(find.text('Premier League'), findsOneWidget);

      await tester.tap(find.byKey(const Key('competitions.item.c-1')));
      await tester.pumpAndSettle();

      // Now on the seasons screen for that competition.
      expect(find.byKey(const Key('seasons.title')), findsOneWidget);
      expect(find.text('2026/27'), findsOneWidget);
    });
  });

  group('RoundFixturesScreen', () {
    testWidgets('round header + fixtures list on success', (tester) async {
      final harness = buildCompetitionHarness((request) async {
        final path = request.url.path;
        if (path == '/rounds/r-1') {
          return okJsonObject(sampleRound.toJson());
        }
        if (path == '/rounds/r-1/fixtures') {
          return okJsonList([sampleFixture.toJson()]);
        }
        return okJsonList(<Object>[]);
      });
      addTearDown(harness.dispose);

      await tester.pumpWidget(
        _host(harness, const RoundFixturesScreen(roundId: 'r-1')),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('fixtures.roundHeader')), findsOneWidget);
      // Ruleset *version* is shown; the opaque snapshot never is.
      expect(find.textContaining('Rules v3'), findsOneWidget);
      expect(find.byKey(const Key('fixtures.item.f-1')), findsOneWidget);
    });

    testWidgets('empty fixtures -> legitimate empty affordance', (
      tester,
    ) async {
      final harness = buildCompetitionHarness((request) async {
        final path = request.url.path;
        if (path == '/rounds/r-1') {
          return okJsonObject(sampleRound.toJson());
        }
        return okJsonList(<Object>[]); // no fixtures
      });
      addTearDown(harness.dispose);

      await tester.pumpWidget(
        _host(harness, const RoundFixturesScreen(roundId: 'r-1')),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('fixtures.roundHeader')), findsOneWidget);
      expect(find.byKey(const Key('browse.empty')), findsOneWidget);
    });

    testWidgets('unknown round (404) -> not-found message, no fixtures list', (
      tester,
    ) async {
      final harness = buildCompetitionHarness((request) async {
        final path = request.url.path;
        if (path == '/rounds/missing') {
          return errorEnvelope(
            404,
            'competition.round_not_found',
            'No such round.',
          );
        }
        return okJsonList(<Object>[]);
      });
      addTearDown(harness.dispose);

      await tester.pumpWidget(
        _host(harness, const RoundFixturesScreen(roundId: 'missing')),
      );
      await tester.pumpAndSettle();

      // The header read fails with the not-found error, rendered via
      // ErrorPresenter — distinct from an empty fixtures list.
      expect(find.byKey(const Key('browse.error')), findsOneWidget);
      expect(find.text('This round could not be found.'), findsOneWidget);
      // A not-found (invariant) failure is NOT retryable — no retry button.
      expect(find.byKey(const Key('browse.error.retry')), findsNothing);
    });
  });
}
