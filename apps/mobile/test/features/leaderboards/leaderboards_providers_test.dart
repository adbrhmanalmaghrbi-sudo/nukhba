/// Unit tests for the Leaderboards (view) provider, at the same depth as the
/// Competition browse `competition_providers_test.dart`: a success case, the
/// legitimate-empty case, a non-member authorization case, a malformed-season-id
/// validation case, and a transport-error case. Each drives the *real*
/// `seasonLeaderboardProvider` over `buildLeaderboardsHarness` (a `MockClient`
/// transport feeding the genuine `api_client` `LeaderboardsApi`), asserting both
/// the resolved value and the outbound method+path, and that a failure surfaces
/// as a typed [AppError] off the provider's future (thrown, so the UI sees
/// `AsyncError`).
library;

import 'package:contracts/contracts.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/features/leaderboards/leaderboards_providers.dart';
import 'package:shared/shared.dart';

import '../../support/leaderboards_harness.dart';

void main() {
  group('seasonLeaderboardProvider (GET /seasons/{id}/leaderboard)', () {
    test('success -> the ranked standings in server display order', () async {
      final harness = buildLeaderboardsHarness(
        (_) async => okJsonObject(sampleBoard.toJson()),
      );
      addTearDown(harness.dispose);

      final board = await harness.container.read(
        seasonLeaderboardProvider('s-1').future,
      );

      // The DTO is echoed verbatim — the client never re-sorts or recomputes.
      expect(board, sampleBoard);
      expect(board.entries.first.rank, 1);
      expect(board.entries.first.participantId, 'p-a');
      expect(board.entries.first.totalPoints, 12);
      expect(harness.captured.single.request.method, 'GET');
      expect(
        harness.captured.single.request.url.path,
        '/seasons/s-1/leaderboard',
      );
      // The transport attached the bearer token like production.
      expect(
        harness.captured.single.request.headers['authorization'],
        'Bearer board-jwt',
      );
    });

    test('a season with no participants -> a legitimate empty board, NOT '
        'an error', () async {
      final harness = buildLeaderboardsHarness(
        (_) async => okJsonObject(emptyBoard.toJson()),
      );
      addTearDown(harness.dispose);

      final board = await harness.container.read(
        seasonLeaderboardProvider('s-2').future,
      );

      expect(board.seasonId, 's-2');
      expect(board.entries, isEmpty);
    });

    test('non-member (401 leaderboard.not_a_participant) -> throws an '
        'authorization AppError carrying the code', () async {
      final harness = buildLeaderboardsHarness(
        (_) async => errorEnvelope(
          401,
          'leaderboard.not_a_participant',
          'Not a member of this season.',
        ),
      );
      addTearDown(harness.dispose);

      await expectLater(
        harness.container.read(seasonLeaderboardProvider('s-1').future),
        throwsA(
          isA<AppError>()
              .having((e) => e.kind, 'kind', ErrorKind.authorization)
              .having((e) => e.code, 'code', 'leaderboard.not_a_participant'),
        ),
      );
    });

    test('malformed season id (400) -> throws a validation AppError', () async {
      final harness = buildLeaderboardsHarness(
        (_) async => errorEnvelope(
          400,
          'leaderboard.season_id_malformed',
          'Malformed season id.',
        ),
      );
      addTearDown(harness.dispose);

      await expectLater(
        harness.container.read(seasonLeaderboardProvider('not-a-uuid').future),
        throwsA(
          isA<AppError>().having((e) => e.kind, 'kind', ErrorKind.validation),
        ),
      );
    });

    test('transport failure -> throws a typed transient AppError', () async {
      final harness = buildLeaderboardsHarness(
        (_) async => throw Exception('socket reset'),
      );
      addTearDown(harness.dispose);

      await expectLater(
        harness.container.read(seasonLeaderboardProvider('s-1').future),
        throwsA(
          isA<AppError>().having((e) => e.kind, 'kind', ErrorKind.transient),
        ),
      );
    });

    test(
      'server 503 -> throws a typed transient AppError (retryable)',
      () async {
        final harness = buildLeaderboardsHarness(
          (_) async => errorEnvelope(
            503,
            'leaderboard.unavailable',
            'Temporarily unavailable.',
          ),
        );
        addTearDown(harness.dispose);

        await expectLater(
          harness.container.read(seasonLeaderboardProvider('s-1').future),
          throwsA(
            isA<AppError>()
                .having((e) => e.kind, 'kind', ErrorKind.transient)
                .having((e) => e.isRetryable, 'isRetryable', isTrue),
          ),
        );
      },
    );
  });
}
