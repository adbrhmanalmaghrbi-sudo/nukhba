import 'dart:io';

import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:server/composition/composition_root.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import 'competition_route_harness.dart';
// ignore: always_use_package_imports
import '../../routes/seasons/[id]/rounds/index.dart' as route;

void main() {
  group('POST /seasons/{id}/rounds', () {
    late InMemoryCompetitionRepository repo;

    CompositionRoot rootWith({bool withSeason = true}) {
      repo = InMemoryCompetitionRepository();
      final compId =
          (CompetitionId.tryParse(kCompetitionId) as Ok<CompetitionId>).value;
      final seasonId = (SeasonId.tryParse(kSeasonId) as Ok<SeasonId>).value;
      repo.competitions[kCompetitionId] = Competition.fromStored(
        id: compId,
        name: 'Comp',
        format: FormatType.footballScoreline,
        visibility: CompetitionVisibility.public,
      );
      if (withSeason) {
        repo.seasons[kSeasonId] = CompetitionSeason.fromStored(
          id: seasonId,
          competitionId: compId,
          label: '2026/27',
        );
      }
      return CompositionRoot.forTesting(
        openRound: OpenRound(
          repository: repo,
          rulesetProvider: const FixedRulesetProvider(),
          idGenerator: ScriptedIdGenerator([kRoundId]),
        ),
      );
    }

    test('opens a round with a frozen ruleset and returns 201', () async {
      final context = wireContext(
        root: rootWith(),
        principal: adminPrincipal(),
        body: const {
          'sequence': 1,
          'prediction_deadline': '2026-08-01T12:00:00Z',
        },
      );

      final response = await route.onRequest(context, kSeasonId);

      expect(response.statusCode, HttpStatus.created);
      final body = await decodeBody(response);
      expect(body['id'], kRoundId);
      expect(body['season_id'], kSeasonId);
      expect(body['sequence'], 1);
      expect(body['status'], 'open');
      expect(body['ruleset_version'], 1);
      // The DTO deliberately never leaks the opaque ruleset payload.
      expect(body.containsKey('ruleset_snapshot'), isFalse);
    });

    test('a malformed deadline is 400 validation', () async {
      final context = wireContext(
        root: rootWith(),
        principal: adminPrincipal(),
        body: const {'sequence': 1, 'prediction_deadline': 'not-a-date'},
      );

      final response = await route.onRequest(context, kSeasonId);

      expect(response.statusCode, HttpStatus.badRequest);
      final body = await decodeBody(response);
      expect(body['code'], 'request.deadline_malformed');
    });

    test('an absent deadline field is 400', () async {
      final context = wireContext(
        root: rootWith(),
        principal: adminPrincipal(),
        body: const {'sequence': 1},
      );

      final response = await route.onRequest(context, kSeasonId);

      expect(response.statusCode, HttpStatus.badRequest);
    });

    test('a missing season surfaces as 409 season_not_found', () async {
      final context = wireContext(
        root: rootWith(withSeason: false),
        principal: adminPrincipal(),
        body: const {
          'sequence': 1,
          'prediction_deadline': '2026-08-01T12:00:00Z',
        },
      );

      final response = await route.onRequest(context, kSeasonId);

      expect(response.statusCode, HttpStatus.conflict);
      final body = await decodeBody(response);
      expect(body['code'], 'competition.season_not_found');
    });

    test('a non-admin principal is rejected with 401', () async {
      final context = wireContext(
        root: rootWith(),
        principal: userPrincipal(),
        body: const {
          'sequence': 1,
          'prediction_deadline': '2026-08-01T12:00:00Z',
        },
      );

      final response = await route.onRequest(context, kSeasonId);

      expect(response.statusCode, HttpStatus.unauthorized);
    });
  });
}
