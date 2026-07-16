import 'dart:io';

import 'package:application/application.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:mocktail/mocktail.dart';
import 'package:server/composition/composition_root.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

// dart_frog routes live outside `lib/`, so they have no `package:` URI; a
// relative import is the only way to unit-test the handler in isolation (the
// pattern documented by Very Good Ventures). We locally waive the
// workspace-wide `always_use_package_imports` rule for this single line.
// ignore: always_use_package_imports
import '../../routes/health.dart' as route;

/// In-memory fake of the health port (Coding Standards ADR, Section 6:
/// use-cases are tested against in-memory fakes, no infrastructure). Mirrors
/// the fake used in `application/test/check_health_test.dart` so the route
/// test exercises the *real* CheckHealth wiring, not a stubbed use-case.
final class _FakeHealthRepository implements HealthRepository {
  _FakeHealthRepository(this._response);

  final Result<bool> _response;

  @override
  Future<Result<bool>> pingDatabase() async => _response;
}

/// `RequestContext` and `Request` are abstract in dart_frog, so mocking them
/// with mocktail is legal (unlike `implements CompositionRoot`, which is
/// impossible because the class is `final`).
class _MockRequestContext extends Mock implements RequestContext {}

class _MockRequest extends Mock implements Request {}

/// Builds a real composition root around a CheckHealth wired to [dbReachable],
/// then a context that provides it exactly as the production middleware does
/// (`provider<Future<CompositionRoot>>`), for the given HTTP [method].
({_MockRequestContext context, Future<CompositionRoot> root}) _wire({
  required bool dbReachable,
  HttpMethod method = HttpMethod.get,
}) {
  final useCase = CheckHealth(_FakeHealthRepository(Result.ok(dbReachable)));
  final root = Future<CompositionRoot>.value(
    CompositionRoot.forTesting(checkHealth: useCase),
  );

  final request = _MockRequest();
  when(() => request.method).thenReturn(method);

  final context = _MockRequestContext();
  when(() => context.request).thenReturn(request);
  // `read` returns a Future here, so mocktail requires `thenAnswer` rather
  // than `thenReturn` (the latter rejects Future return values).
  when(() => context.read<Future<CompositionRoot>>()).thenAnswer((_) => root);

  return (context: context, root: root);
}

/// Decodes a dart_frog JSON [Response] body into a typed map, keeping the
/// `strict-casts` / `strict-raw-types` analyzer happy at the call sites.
Future<Map<String, Object?>> _decodeBody(Response response) async {
  final decoded = await response.json() as Map<Object?, Object?>;
  return decoded.cast<String, Object?>();
}

void main() {
  group('GET /health route', () {
    test(
      'returns 200 with healthy body when the database is reachable',
      () async {
        final wired = _wire(dbReachable: true);

        final response = await route.onRequest(wired.context);

        expect(response.statusCode, HttpStatus.ok);
        final body = await _decodeBody(response);
        expect(body['status'], 'healthy');
        expect(body['database_reachable'], isTrue);
        expect(body['schema_version'], 1);
      },
    );

    test('returns 503 with unhealthy body when the database is '
        'unreachable', () async {
      final wired = _wire(dbReachable: false);

      final response = await route.onRequest(wired.context);

      expect(response.statusCode, HttpStatus.serviceUnavailable);
      final body = await _decodeBody(response);
      expect(body['status'], 'unhealthy');
      expect(body['database_reachable'], isFalse);
    });

    test(
      'rejects non-GET methods with 405 without touching the use-case',
      () async {
        final wired = _wire(dbReachable: true, method: HttpMethod.post);

        final response = await route.onRequest(wired.context);

        expect(response.statusCode, HttpStatus.methodNotAllowed);
        // The root must not be read when the method is rejected up front.
        verifyNever(() => wired.context.read<Future<CompositionRoot>>());
      },
    );
  });
}
