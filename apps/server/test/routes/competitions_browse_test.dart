import 'dart:io';

import 'package:application/application.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:domain/domain.dart';
import 'package:server/composition/composition_root.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import 'competition_route_harness.dart';
// dart_frog routes have no `package:` URI (they live outside `lib/`); a relative
// import is the documented way to unit-test the handler in isolation.
// ignore: always_use_package_imports
import '../../routes/competitions/index.dart' as list_route;
// ignore: always_use_package_imports
import '../../routes/competitions/[id]/index.dart' as detail_route;

/// Route tests for the Competition *browse* read surface added under BLOCKER
/// FA-1 (2026-07-13): `GET /competitions` (`_list`) and `GET /competitions/{id}`.
///
/// Tested through the real wiring (`context.read<Future<CompositionRoot>>()` →
/// `root.listCompetitions()` / `root.getCompetition()`) over an in-memory
/// [InMemoryCompetitionRepository], exactly like every other route test — so the
/// assertions cover the route's status mapping, DTO shaping, and public-only
/// filtering for real, edge → use-case → domain → port.
///
/// Auth note: a "no bearer token → 401" case is deliberately NOT tested here.
/// That refusal is the `bearerAuth` middleware's responsibility (it rejects the
/// request before the handler runs and injects the `AuthenticatedUser`); the
/// handler is only ever reached WITH a principal, mirrored by `wireContext`
/// requiring one — the same convention every existing route test follows
/// (`me_test`, `competitions_index_test`, `scoring_routes_test`, …). Both browse
/// reads gate on `PlatformRole.user`, which every authenticated principal
/// satisfies, so the route itself never produces `auth.insufficient_role` on the
/// read path.
void main() {
  /// A public competition built via the real `create` factory (validated),
  /// stored directly so the browse reads see it.
  Competition publicCompetition(String id, String name) {
    final built = Competition.create(
      id: CompetitionId(id),
      name: name,
      format: FormatType.footballScoreline,
      visibility: CompetitionVisibility.public,
    );
    return (built as Ok<Competition>).value;
  }

  /// A private competition — must NOT appear in the discoverable catalogue.
  Competition privateCompetition(String id, String name) {
    final built = Competition.create(
      id: CompetitionId(id),
      name: name,
      format: FormatType.footballScoreline,
      visibility: CompetitionVisibility.private,
    );
    return (built as Ok<Competition>).value;
  }

  group('GET /competitions (browse list)', () {
    late InMemoryCompetitionRepository repo;

    CompositionRoot rootWith() {
      repo = InMemoryCompetitionRepository();
      return CompositionRoot.forTesting(
        listCompetitions: ListCompetitions(repository: repo),
      );
    }

    test(
      'returns 200 with ONLY public competitions, name-then-id ordered',
      () async {
        final root = rootWith();
        // Seeded out of order + one private, to prove filtering + ordering.
        repo.competitions['33333333-3333-3333-3333-333333333333'] =
            publicCompetition(
              '33333333-3333-3333-3333-333333333333',
              'World Cup 2026',
            );
        repo.competitions['11111111-1111-1111-1111-111111111111'] =
            publicCompetition(
              '11111111-1111-1111-1111-111111111111',
              'Champions League',
            );
        repo.competitions['22222222-2222-2222-2222-222222222222'] =
            privateCompetition(
              '22222222-2222-2222-2222-222222222222',
              'Private League',
            );

        final context = wireContext(
          root: root,
          principal: userPrincipal(),
          method: HttpMethod.get,
        );

        final response = await list_route.onRequest(context);

        expect(response.statusCode, HttpStatus.ok);
        final body = await response.json() as List<Object?>;
        final items = body.cast<Map<String, Object?>>();
        // Private one excluded; the two public ones in name order.
        expect(items, hasLength(2));
        expect(items[0]['name'], 'Champions League');
        expect(items[1]['name'], 'World Cup 2026');
        // Shape is the versioned CompetitionDto.
        expect(items[0]['schema_version'], 1);
        expect(items[0]['id'], '11111111-1111-1111-1111-111111111111');
        expect(items[0]['format'], 'football_scoreline');
        expect(items[0]['visibility'], 'public');
      },
    );

    test(
      'an empty catalogue is a legitimate 200 with an empty array',
      () async {
        final context = wireContext(
          root: rootWith(),
          principal: userPrincipal(),
          method: HttpMethod.get,
        );

        final response = await list_route.onRequest(context);

        expect(response.statusCode, HttpStatus.ok);
        final body = await response.json() as List<Object?>;
        expect(body, isEmpty);
      },
    );

    test('an admin principal may also browse the catalogue (200)', () async {
      final root = rootWith();
      repo.competitions[kCompetitionId] = publicCompetition(
        kCompetitionId,
        'Premier League',
      );

      final context = wireContext(
        root: root,
        principal: adminPrincipal(),
        method: HttpMethod.get,
      );

      final response = await list_route.onRequest(context);

      expect(response.statusCode, HttpStatus.ok);
      final body = await response.json() as List<Object?>;
      expect(body, hasLength(1));
    });
  });

  group('GET /competitions/{id} (browse detail)', () {
    late InMemoryCompetitionRepository repo;

    CompositionRoot rootWith() {
      repo = InMemoryCompetitionRepository();
      return CompositionRoot.forTesting(
        getCompetition: GetCompetition(repository: repo),
      );
    }

    test('returns 200 with the single competition DTO', () async {
      final root = rootWith();
      repo.competitions[kCompetitionId] = publicCompetition(
        kCompetitionId,
        'Premier League Predictor',
      );

      final context = wireContext(
        root: root,
        principal: userPrincipal(),
        method: HttpMethod.get,
      );

      final response = await detail_route.onRequest(context, kCompetitionId);

      expect(response.statusCode, HttpStatus.ok);
      final body = await decodeBody(response);
      expect(body['schema_version'], 1);
      expect(body['id'], kCompetitionId);
      expect(body['name'], 'Premier League Predictor');
      expect(body['format'], 'football_scoreline');
      expect(body['visibility'], 'public');
    });

    test('an unknown id is 404 with code competition.not_found', () async {
      final context = wireContext(
        root: rootWith(),
        principal: userPrincipal(),
        method: HttpMethod.get,
      );

      final response = await detail_route.onRequest(
        context,
        // Well-formed UUID, just not stored.
        '44444444-4444-4444-4444-444444444444',
      );

      expect(response.statusCode, HttpStatus.notFound);
      final body = await decodeBody(response);
      expect(body['code'], 'competition.not_found');
    });

    test('a malformed id is 400 (validation), not 404', () async {
      final context = wireContext(
        root: rootWith(),
        principal: userPrincipal(),
        method: HttpMethod.get,
      );

      final response = await detail_route.onRequest(context, 'not-a-uuid');

      expect(response.statusCode, HttpStatus.badRequest);
      final body = await decodeBody(response);
      // The id value object rejects a non-UUID as a validation error; the
      // envelope maps `validation` → 400, distinct from the not-found 404.
      expect(body['code'], isNot('competition.not_found'));
    });

    test('an unsupported method (POST) on {id} is 405', () async {
      final context = wireContext(root: rootWith(), principal: userPrincipal());

      final response = await detail_route.onRequest(context, kCompetitionId);

      expect(response.statusCode, HttpStatus.methodNotAllowed);
    });
  });
}
