import 'dart:io';

import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:server/composition/composition_root.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import 'competition_route_harness.dart';
// dart_frog routes have no `package:` URI (they live outside `lib/`); a relative
// import is the documented way to unit-test the handler in isolation.
// ignore: always_use_package_imports
import '../../routes/rounds/[id]/index.dart' as round_route;
// ignore: always_use_package_imports
import '../../routes/rounds/[id]/fixtures/index.dart' as fixtures_route;

/// Route tests for the Round *browse* read surface added under BLOCKER FA-1
/// (2026-07-13): `GET /rounds/{id}` (new file) and the new `GET` branch of
/// `GET /rounds/{id}/fixtures` (added beside the untouched `POST` command).
///
/// Tested through the real wiring (`context.read<Future<CompositionRoot>>()` →
/// `root.getRound()` / `root.listRoundFixtures()`) over the in-memory
/// [InMemoryCompetitionRepository], mirroring `scoring_routes_test.dart` /
/// `round_predictions_test.dart` — edge → use-case → domain → port.
///
/// Auth note: a "no bearer token → 401" case is deliberately NOT tested here —
/// that refusal is the `bearerAuth` middleware's job (the `/rounds` subtree
/// applies it via `rounds/_middleware.dart`), before the handler runs; the
/// handler is only reached WITH a principal, mirrored by `wireContext` requiring
/// one. Both reads gate on `PlatformRole.user`, which every authenticated
/// principal satisfies.
void main() {
  final roundId = (RoundId.tryParse(kRoundId) as Ok<RoundId>).value;

  /// The exact `football_scoreline` payload the production
  /// `ConfiguredRulesetProvider` freezes at open time (matches the shape used by
  /// `scoring_routes_test.dart`), so the stored round rehydrates faithfully.
  RulesetSnapshot snapshot() =>
      (RulesetSnapshot.create(
                payload: const {
                  'format': 'football_scoreline',
                  'points': {
                    'exact_scoreline': 3,
                    'correct_outcome': 1,
                    'incorrect': 0,
                  },
                },
                rulesetVersion: 1,
              )
              as Ok<RulesetSnapshot>)
          .value;

  Round roundIn(RoundStatus status) => Round.fromStored(
    id: roundId,
    seasonId: (SeasonId.tryParse(kSeasonId) as Ok<SeasonId>).value,
    sequence: 1,
    predictionDeadline: DateTime.utc(2026, 8, 1, 12),
    status: status,
    ruleset: snapshot(),
  );

  RoundFixture link(String fixtureId, int order) => RoundFixture.fromStored(
    roundId: roundId,
    fixture: (FixtureRef.tryParse(fixtureId) as Ok<FixtureRef>).value,
    displayOrder: order,
  );

  group('GET /rounds/{id}', () {
    late InMemoryCompetitionRepository repo;

    CompositionRoot rootWith() {
      repo = InMemoryCompetitionRepository();
      return CompositionRoot.forTesting(getRound: GetRound(repository: repo));
    }

    test(
      'returns 200 with the round DTO (ruleset version only, no snapshot)',
      () async {
        final root = rootWith();
        repo.rounds[kRoundId] = roundIn(RoundStatus.open);

        final context = wireContext(
          root: root,
          principal: userPrincipal(),
          method: HttpMethod.get,
        );

        final response = await round_route.onRequest(context, kRoundId);

        expect(response.statusCode, HttpStatus.ok);
        final body = await decodeBody(response);
        expect(body['schema_version'], 1);
        expect(body['id'], kRoundId);
        expect(body['season_id'], kSeasonId);
        expect(body['sequence'], 1);
        expect(body['status'], 'open');
        expect(body['ruleset_version'], 1);
        // Integrity boundary: the opaque frozen ruleset payload is never exposed.
        expect(body.containsKey('ruleset'), isFalse);
      },
    );

    test(
      'an unknown round id is 404 with code competition.round_not_found',
      () async {
        final context = wireContext(
          root: rootWith(),
          principal: userPrincipal(),
          method: HttpMethod.get,
        );

        final response = await round_route.onRequest(
          context,
          // Well-formed UUID, just not stored.
          '55555555-5555-5555-5555-555555555555',
        );

        expect(response.statusCode, HttpStatus.notFound);
        final body = await decodeBody(response);
        expect(body['code'], 'competition.round_not_found');
      },
    );

    test('a malformed round id is 400 (validation), not 404', () async {
      final context = wireContext(
        root: rootWith(),
        principal: userPrincipal(),
        method: HttpMethod.get,
      );

      final response = await round_route.onRequest(context, 'not-a-uuid');

      expect(response.statusCode, HttpStatus.badRequest);
      final body = await decodeBody(response);
      expect(body['code'], isNot('competition.round_not_found'));
    });

    test('an unsupported method (POST) on {id} is 405', () async {
      final context = wireContext(root: rootWith(), principal: userPrincipal());

      final response = await round_route.onRequest(context, kRoundId);

      expect(response.statusCode, HttpStatus.methodNotAllowed);
    });
  });

  group('GET /rounds/{id}/fixtures', () {
    late InMemoryCompetitionRepository repo;

    CompositionRoot rootWith() {
      repo = InMemoryCompetitionRepository();
      return CompositionRoot.forTesting(
        listRoundFixtures: ListRoundFixtures(repository: repo),
        // The POST branch is exercised elsewhere; wiring only the read here
        // keeps this group focused on the new GET branch.
      );
    }

    test(
      'returns 200 with the fixtures in display_order, then fixture id',
      () async {
        final root = rootWith();
        // Seeded out of order to prove the ordering.
        repo.links.add(link('cccccccc-cccc-cccc-cccc-cccccccccccc', 2));
        repo.links.add(link(kFixtureId, 1));

        final context = wireContext(
          root: root,
          principal: userPrincipal(),
          method: HttpMethod.get,
        );

        final response = await fixtures_route.onRequest(context, kRoundId);

        expect(response.statusCode, HttpStatus.ok);
        final body = await response.json() as List<Object?>;
        final items = body.cast<Map<String, Object?>>();
        expect(items, hasLength(2));
        // display_order 1 first, then 2.
        expect(items[0]['fixture_id'], kFixtureId);
        expect(items[0]['display_order'], 1);
        expect(items[1]['fixture_id'], 'cccccccc-cccc-cccc-cccc-cccccccccccc');
        expect(items[1]['display_order'], 2);
        // Shape is the versioned RoundFixtureDto.
        expect(items[0]['schema_version'], 1);
        expect(items[0]['round_id'], kRoundId);
      },
    );

    test('a round with no linked fixtures is a legitimate 200 empty array (no '
        'existence oracle)', () async {
      final context = wireContext(
        root: rootWith(),
        principal: userPrincipal(),
        method: HttpMethod.get,
      );

      // Nothing seeded, and the round id itself is never even looked up — the
      // fixtures list use-case never 404s (no existence oracle by design).
      final response = await fixtures_route.onRequest(
        context,
        '66666666-6666-6666-6666-666666666666',
      );

      expect(response.statusCode, HttpStatus.ok);
      final body = await response.json() as List<Object?>;
      expect(body, isEmpty);
    });

    test('an unsupported method (DELETE) is 405', () async {
      final context = wireContext(
        root: rootWith(),
        principal: userPrincipal(),
        method: HttpMethod.delete,
      );

      final response = await fixtures_route.onRequest(context, kRoundId);

      expect(response.statusCode, HttpStatus.methodNotAllowed);
    });
  });
}
