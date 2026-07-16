import 'dart:io';

import 'package:application/application.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:domain/domain.dart';
import 'package:mocktail/mocktail.dart';
import 'package:server/composition/composition_root.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

// dart_frog routes have no `package:` URI (they live outside `lib/`); a
// relative import is the documented way to unit-test the handler in isolation.
// ignore: always_use_package_imports
import '../../routes/me/index.dart' as route;

const _uuid = '11111111-2222-3333-4444-555555555555';

/// In-memory [UserDirectory] fake, so the route test exercises the real
/// GetCurrentUser wiring rather than a stubbed use-case.
final class _FakeUserDirectory implements UserDirectory {
  _FakeUserDirectory(this._response);
  final Result<User> _response;

  @override
  Future<Result<User>> ensureUser(AuthenticatedUser principal) async =>
      _response;
}

class _MockRequestContext extends Mock implements RequestContext {}

class _MockRequest extends Mock implements Request {}

AuthenticatedUser _principal() => AuthenticatedUser(
  userId: const UserId(_uuid),
  role: PlatformRole.user,
  email: 'a@example.com',
);

/// Wires a context that provides a real composition root (GetCurrentUser over
/// [directoryResponse]) plus an already-established [principal], exactly as the
/// bearerAuth middleware would at runtime.
_MockRequestContext _wire({
  required Result<User> directoryResponse,
  HttpMethod method = HttpMethod.get,
  AuthenticatedUser? principal,
}) {
  final root = Future<CompositionRoot>.value(
    CompositionRoot.forTesting(
      getCurrentUser: GetCurrentUser(_FakeUserDirectory(directoryResponse)),
    ),
  );

  final request = _MockRequest();
  when(() => request.method).thenReturn(method);

  final context = _MockRequestContext();
  when(() => context.request).thenReturn(request);
  when(() => context.read<Future<CompositionRoot>>()).thenAnswer((_) => root);
  when(
    () => context.read<AuthenticatedUser>(),
  ).thenReturn(principal ?? _principal());

  return context;
}

Future<Map<String, Object?>> _decodeBody(Response response) async {
  final decoded = await response.json() as Map<Object?, Object?>;
  return decoded.cast<String, Object?>();
}

void main() {
  group('GET /me route', () {
    test('returns 200 with the canonical user projection', () async {
      final canonical = User(
        id: const UserId(_uuid),
        email: 'a@example.com',
        // Platform-owned role/status are what the response must reflect,
        // even though the token principal was a plain `user`.
        role: PlatformRole.admin,
        status: UserStatus.active,
      );
      final context = _wire(directoryResponse: Result.ok(canonical));

      final response = await route.onRequest(context);

      expect(response.statusCode, HttpStatus.ok);
      final body = await _decodeBody(response);
      expect(body['schema_version'], 1);
      final user = (body['user']! as Map).cast<String, Object?>();
      expect(user['user_id'], _uuid);
      expect(user['role'], 'admin'); // authoritative platform value
      expect(user['status'], 'active');
      expect(user['email'], 'a@example.com');
    });

    test('returns 503 when the directory fails transiently', () async {
      final context = _wire(
        directoryResponse: const Result.err(
          AppError.transient('identity.upsert_no_row', 'no row'),
        ),
      );

      final response = await route.onRequest(context);

      expect(response.statusCode, HttpStatus.serviceUnavailable);
      final body = await _decodeBody(response);
      expect(body['code'], 'identity.upsert_no_row');
    });

    test('rejects non-GET methods with 405 without reading the root', () async {
      final context = _wire(
        directoryResponse: Result.ok(
          User(
            id: const UserId(_uuid),
            email: null,
            role: PlatformRole.user,
            status: UserStatus.active,
          ),
        ),
        method: HttpMethod.post,
      );

      final response = await route.onRequest(context);

      expect(response.statusCode, HttpStatus.methodNotAllowed);
      verifyNever(() => context.read<Future<CompositionRoot>>());
    });
  });
}
