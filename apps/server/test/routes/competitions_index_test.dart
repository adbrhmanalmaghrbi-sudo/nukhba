import 'dart:io';

import 'package:application/application.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:server/composition/composition_root.dart';
import 'package:test/test.dart';

import 'competition_route_harness.dart';
// dart_frog routes have no `package:` URI (they live outside `lib/`); a relative
// import is the documented way to unit-test the handler in isolation.
// ignore: always_use_package_imports
import '../../routes/competitions/index.dart' as route;

void main() {
  group('POST /competitions', () {
    late InMemoryCompetitionRepository repo;

    CompositionRoot rootWith() {
      repo = InMemoryCompetitionRepository();
      return CompositionRoot.forTesting(
        createCompetition: CreateCompetition(
          repository: repo,
          idGenerator: ScriptedIdGenerator([kCompetitionId]),
        ),
      );
    }

    test('creates a competition and returns 201 with the DTO', () async {
      final context = wireContext(
        root: rootWith(),
        principal: adminPrincipal(),
        body: const {
          'name': 'Premier League Predictor',
          'format': 'football_scoreline',
          'visibility': 'public',
        },
      );

      final response = await route.onRequest(context);

      expect(response.statusCode, HttpStatus.created);
      final body = await decodeBody(response);
      expect(body['schema_version'], 1);
      expect(body['id'], kCompetitionId);
      expect(body['name'], 'Premier League Predictor');
      expect(body['format'], 'football_scoreline');
      expect(body['visibility'], 'public');
      // The aggregate really landed in the repository.
      expect(repo.competitions[kCompetitionId], isNotNull);
    });

    test('rejects a non-admin principal with 401', () async {
      final context = wireContext(
        root: rootWith(),
        principal: userPrincipal(),
        body: const {
          'name': 'X',
          'format': 'football_scoreline',
          'visibility': 'public',
        },
      );

      final response = await route.onRequest(context);

      expect(response.statusCode, HttpStatus.unauthorized);
      final body = await decodeBody(response);
      expect(body['code'], 'auth.insufficient_role');
      expect(repo.competitions, isEmpty);
    });

    test('maps an unknown format to 400 validation', () async {
      final context = wireContext(
        root: rootWith(),
        principal: adminPrincipal(),
        body: const {'name': 'X', 'format': 'chess', 'visibility': 'public'},
      );

      final response = await route.onRequest(context);

      expect(response.statusCode, HttpStatus.badRequest);
      final body = await decodeBody(response);
      expect(body['code'], 'competition.format_type_unknown');
    });

    test('a missing required field is 400 without authorizing', () async {
      final context = wireContext(
        root: rootWith(),
        principal: adminPrincipal(),
        body: const {'format': 'football_scoreline', 'visibility': 'public'},
      );

      final response = await route.onRequest(context);

      expect(response.statusCode, HttpStatus.badRequest);
      final body = await decodeBody(response);
      expect(body['code'], 'request.field_missing');
    });

    // NOTE: `GET` is no longer a 405 — the BLOCKER FA-1 patch added the
    // read-only `_list` browse branch. GET's behaviour is covered in full by
    // `competitions_browse_test.dart`; here we only assert a genuinely
    // unsupported method (`DELETE`) still maps to 405 on this collection.
    test('an unsupported method (DELETE) is 405', () async {
      final context = wireContext(
        root: rootWith(),
        principal: adminPrincipal(),
        method: HttpMethod.delete,
      );

      final response = await route.onRequest(context);

      expect(response.statusCode, HttpStatus.methodNotAllowed);
    });
  });
}
