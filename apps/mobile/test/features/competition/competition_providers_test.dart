/// Unit tests for the six Competition **browse** providers, at the same depth
/// as the Auth `session_controller_test.dart`: for each provider a success case,
/// the legitimate-empty case (for the list reads) or the not-found case (for the
/// single-item reads), and a transport-error case. Each drives the *real*
/// provider over `buildCompetitionHarness` (a `MockClient` transport feeding the
/// genuine `api_client` `CompetitionApi`), asserting both the resolved value and
/// the outbound method+path, and that a failure surfaces as a typed [AppError]
/// off the provider's future (thrown, so the UI sees `AsyncError`).
library;

import 'package:contracts/contracts.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/features/competition/competition_providers.dart';
import 'package:shared/shared.dart';

import '../../support/competition_harness.dart';

void main() {
  // -------------------------------------------------------------------------
  // Level 1: competitionListProvider — GET /competitions
  // -------------------------------------------------------------------------
  group('competitionListProvider (GET /competitions)', () {
    test('success -> the catalogue in server order', () async {
      final harness = buildCompetitionHarness(
        (_) async => okJsonList([
          sampleCompetition.toJson(),
          sampleCompetition2.toJson(),
        ]),
      );
      addTearDown(harness.dispose);

      final list = await harness.container.read(competitionListProvider.future);

      expect(list, [sampleCompetition, sampleCompetition2]);
      expect(harness.captured.single.request.method, 'GET');
      expect(harness.captured.single.request.url.path, '/competitions');
      // The transport attached the bearer token like production.
      expect(
        harness.captured.single.request.headers['authorization'],
        'Bearer browse-jwt',
      );
    });

    test('empty catalogue -> a legitimate empty list, NOT an error', () async {
      final harness = buildCompetitionHarness(
        (_) async => okJsonList(<Object>[]),
      );
      addTearDown(harness.dispose);

      final list = await harness.container.read(competitionListProvider.future);

      expect(list, isEmpty);
    });

    test('transport failure -> throws a typed transient AppError', () async {
      final harness = buildCompetitionHarness(
        (_) async => throw Exception('socket reset'),
      );
      addTearDown(harness.dispose);

      await expectLater(
        harness.container.read(competitionListProvider.future),
        throwsA(
          isA<AppError>().having((e) => e.kind, 'kind', ErrorKind.transient),
        ),
      );
    });
  });

  // -------------------------------------------------------------------------
  // Level 1 detail: competitionDetailProvider — GET /competitions/{id}
  // -------------------------------------------------------------------------
  group('competitionDetailProvider (GET /competitions/{id})', () {
    test('success -> the single competition at the id path', () async {
      final harness = buildCompetitionHarness(
        (_) async => okJsonObject(sampleCompetition.toJson()),
      );
      addTearDown(harness.dispose);

      final dto = await harness.container.read(
        competitionDetailProvider('c-1').future,
      );

      expect(dto, sampleCompetition);
      expect(harness.captured.single.request.url.path, '/competitions/c-1');
    });

    test(
      'unknown id (404 competition.not_found) -> throws invariant AppError',
      () async {
        final harness = buildCompetitionHarness(
          (_) async => errorEnvelope(
            404,
            'competition.not_found',
            'No such competition.',
          ),
        );
        addTearDown(harness.dispose);

        await expectLater(
          harness.container.read(competitionDetailProvider('missing').future),
          throwsA(
            isA<AppError>()
                .having((e) => e.kind, 'kind', ErrorKind.invariant)
                .having((e) => e.code, 'code', 'competition.not_found'),
          ),
        );
      },
    );

    test('transport failure -> throws a typed transient AppError', () async {
      final harness = buildCompetitionHarness(
        (_) async => throw Exception('offline'),
      );
      addTearDown(harness.dispose);

      await expectLater(
        harness.container.read(competitionDetailProvider('c-1').future),
        throwsA(
          isA<AppError>().having((e) => e.kind, 'kind', ErrorKind.transient),
        ),
      );
    });
  });

  // -------------------------------------------------------------------------
  // Level 2: competitionSeasonsProvider — GET /competitions/{id}/seasons
  // -------------------------------------------------------------------------
  group('competitionSeasonsProvider (GET /competitions/{id}/seasons)', () {
    test('success -> the seasons list at the id path', () async {
      final harness = buildCompetitionHarness(
        (_) async => okJsonList([sampleSeason.toJson()]),
      );
      addTearDown(harness.dispose);

      final list = await harness.container.read(
        competitionSeasonsProvider('c-1').future,
      );

      expect(list, [sampleSeason]);
      expect(
        harness.captured.single.request.url.path,
        '/competitions/c-1/seasons',
      );
    });

    test('no seasons / absent competition -> legitimate empty list', () async {
      final harness = buildCompetitionHarness(
        (_) async => okJsonList(<Object>[]),
      );
      addTearDown(harness.dispose);

      final list = await harness.container.read(
        competitionSeasonsProvider('absent').future,
      );

      expect(list, isEmpty);
    });

    test(
      'authorization failure (401) -> throws authorization AppError',
      () async {
        final harness = buildCompetitionHarness(
          (_) async =>
              errorEnvelope(401, 'auth.token_expired', 'Token expired.'),
        );
        addTearDown(harness.dispose);

        await expectLater(
          harness.container.read(competitionSeasonsProvider('c-1').future),
          throwsA(
            isA<AppError>().having(
              (e) => e.kind,
              'kind',
              ErrorKind.authorization,
            ),
          ),
        );
      },
    );
  });

  // -------------------------------------------------------------------------
  // Level 3: seasonRoundsProvider — GET /seasons/{id}/rounds
  // -------------------------------------------------------------------------
  group('seasonRoundsProvider (GET /seasons/{id}/rounds)', () {
    test('success -> the rounds list at the id path', () async {
      final harness = buildCompetitionHarness(
        (_) async => okJsonList([sampleRound.toJson()]),
      );
      addTearDown(harness.dispose);

      final list = await harness.container.read(
        seasonRoundsProvider('s-1').future,
      );

      expect(list, [sampleRound]);
      expect(harness.captured.single.request.url.path, '/seasons/s-1/rounds');
    });

    test('no rounds / absent season -> legitimate empty list', () async {
      final harness = buildCompetitionHarness(
        (_) async => okJsonList(<Object>[]),
      );
      addTearDown(harness.dispose);

      final list = await harness.container.read(
        seasonRoundsProvider('absent').future,
      );

      expect(list, isEmpty);
    });

    test('transport failure -> throws a typed transient AppError', () async {
      final harness = buildCompetitionHarness(
        (_) async => throw Exception('offline'),
      );
      addTearDown(harness.dispose);

      await expectLater(
        harness.container.read(seasonRoundsProvider('s-1').future),
        throwsA(
          isA<AppError>().having((e) => e.kind, 'kind', ErrorKind.transient),
        ),
      );
    });
  });

  // -------------------------------------------------------------------------
  // Level 4 header: roundDetailProvider — GET /rounds/{id}
  // -------------------------------------------------------------------------
  group('roundDetailProvider (GET /rounds/{id})', () {
    test(
      'success -> the single round (no snapshot, only ruleset version)',
      () async {
        final harness = buildCompetitionHarness(
          (_) async => okJsonObject(sampleRound.toJson()),
        );
        addTearDown(harness.dispose);

        final dto = await harness.container.read(
          roundDetailProvider('r-1').future,
        );

        expect(dto, sampleRound);
        expect(dto.rulesetVersion, 3);
        expect(harness.captured.single.request.url.path, '/rounds/r-1');
      },
    );

    test('unknown id (404 competition.round_not_found) -> throws invariant '
        'AppError', () async {
      final harness = buildCompetitionHarness(
        (_) async =>
            errorEnvelope(404, 'competition.round_not_found', 'No such round.'),
      );
      addTearDown(harness.dispose);

      await expectLater(
        harness.container.read(roundDetailProvider('missing').future),
        throwsA(
          isA<AppError>()
              .having((e) => e.kind, 'kind', ErrorKind.invariant)
              .having((e) => e.code, 'code', 'competition.round_not_found'),
        ),
      );
    });

    test('transport failure -> throws a typed transient AppError', () async {
      final harness = buildCompetitionHarness(
        (_) async => throw Exception('offline'),
      );
      addTearDown(harness.dispose);

      await expectLater(
        harness.container.read(roundDetailProvider('r-1').future),
        throwsA(
          isA<AppError>().having((e) => e.kind, 'kind', ErrorKind.transient),
        ),
      );
    });
  });

  // -------------------------------------------------------------------------
  // Level 4 list: roundFixturesProvider — GET /rounds/{id}/fixtures
  // -------------------------------------------------------------------------
  group('roundFixturesProvider (GET /rounds/{id}/fixtures)', () {
    test('success -> the fixtures list at the id path', () async {
      final harness = buildCompetitionHarness(
        (_) async => okJsonList([sampleFixture.toJson()]),
      );
      addTearDown(harness.dispose);

      final list = await harness.container.read(
        roundFixturesProvider('r-1').future,
      );

      expect(list, [sampleFixture]);
      expect(harness.captured.single.request.url.path, '/rounds/r-1/fixtures');
    });

    test('no fixtures / absent round -> legitimate empty list', () async {
      final harness = buildCompetitionHarness(
        (_) async => okJsonList(<Object>[]),
      );
      addTearDown(harness.dispose);

      final list = await harness.container.read(
        roundFixturesProvider('absent').future,
      );

      expect(list, isEmpty);
    });

    test(
      'a malformed element -> throws a validation (malformed) AppError',
      () async {
        final harness = buildCompetitionHarness(
          (_) async => okJsonList(<Object>['not-an-object']),
        );
        addTearDown(harness.dispose);

        await expectLater(
          harness.container.read(roundFixturesProvider('r-1').future),
          throwsA(isA<AppError>()),
        );
      },
    );
  });
}
