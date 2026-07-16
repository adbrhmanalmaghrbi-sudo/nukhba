import 'dart:io';

import 'package:application/application.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:domain/domain.dart';
import 'package:server/composition/composition_root.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import 'competition_route_harness.dart';
// ignore: always_use_package_imports
import '../../routes/seasons/[id]/participants/index.dart' as route;

void main() {
  group('POST /seasons/{id}/participants', () {
    late InMemoryCompetitionRepository repo;
    const participantId = '99999999-9999-9999-9999-999999999999';

    CompositionRoot rootWith({bool withSeason = true}) {
      repo = InMemoryCompetitionRepository();
      if (withSeason) {
        final compId =
            (CompetitionId.tryParse(kCompetitionId) as Ok<CompetitionId>).value;
        repo.seasons[kSeasonId] = CompetitionSeason.fromStored(
          id: (SeasonId.tryParse(kSeasonId) as Ok<SeasonId>).value,
          competitionId: compId,
          label: '2026/27',
        );
      }
      return CompositionRoot.forTesting(
        joinCompetition: JoinCompetition(
          repository: repo,
          idGenerator: ScriptedIdGenerator([participantId]),
          clock: FixedClock(DateTime.utc(2026, 7, 1, 9)),
        ),
      );
    }

    test('enrols the calling user and returns 201', () async {
      final context = wireContext(root: rootWith(), principal: userPrincipal());

      final response = await route.onRequest(context, kSeasonId);

      expect(response.statusCode, HttpStatus.created);
      final body = await decodeBody(response);
      expect(body['id'], participantId);
      expect(body['season_id'], kSeasonId);
      // The enrolled user is taken from the verified token, never a body field.
      expect(body['user_id'], kUserId);
      expect(body['status'], 'active');
      expect(body['joined_at'], DateTime.utc(2026, 7, 1, 9).toIso8601String());
    });

    test(
      'is idempotent: a repeat join returns the existing enrolment',
      () async {
        final root = rootWith();
        final first = await route.onRequest(
          wireContext(root: root, principal: userPrincipal()),
          kSeasonId,
        );
        expect(first.statusCode, HttpStatus.created);

        // Second join, same season/user, same root (so the repo already has the
        // participant). It converges rather than erroring or duplicating.
        final second = await route.onRequest(
          wireContext(root: root, principal: userPrincipal()),
          kSeasonId,
        );

        final body = await decodeBody(second);
        expect(body['id'], participantId);
        expect(repo.participants.length, 1);
      },
    );

    test('a missing season surfaces as 409 season_not_found', () async {
      final context = wireContext(
        root: rootWith(withSeason: false),
        principal: userPrincipal(),
      );

      final response = await route.onRequest(context, kSeasonId);

      expect(response.statusCode, HttpStatus.conflict);
      final body = await decodeBody(response);
      expect(body['code'], 'competition.season_not_found');
    });

    test('a non-POST method is 405', () async {
      final context = wireContext(
        root: rootWith(),
        principal: userPrincipal(),
        method: HttpMethod.get,
      );

      final response = await route.onRequest(context, kSeasonId);

      expect(response.statusCode, HttpStatus.methodNotAllowed);
    });
  });
}
