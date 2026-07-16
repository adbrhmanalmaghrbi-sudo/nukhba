import 'dart:io';

import 'package:application/application.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:domain/domain.dart';
import 'package:mocktail/mocktail.dart';
import 'package:server/composition/composition_root.dart';
import 'package:server/http/bearer_auth.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

const _uuid = '11111111-2222-3333-4444-555555555555';

/// In-memory [TokenVerifier] fake so the middleware test exercises the real
/// AuthenticateRequest wiring (header parse included) against a scripted result.
final class _FakeTokenVerifier implements TokenVerifier {
  _FakeTokenVerifier(this._response);
  final Result<AuthenticatedUser> _response;

  @override
  Future<Result<AuthenticatedUser>> verify(String bearerToken) async =>
      _response;
}

class _MockRequestContext extends Mock implements RequestContext {}

class _MockRequest extends Mock implements Request {}

AuthenticatedUser _principal() =>
    AuthenticatedUser(userId: const UserId(_uuid), role: PlatformRole.user);

void main() {
  setUpAll(() {
    // mocktail needs a fallback for the `provide` closure argument type.
    registerFallbackValue(() => _principal());
  });

  /// Builds a context whose composition root authenticates via [verifierResult]
  /// and whose request carries [authorizationHeader]. The provided principal is
  /// captured so a passing request can be asserted to forward it downstream.
  ({_MockRequestContext context, List<AuthenticatedUser> provided}) _wire({
    required Result<AuthenticatedUser> verifierResult,
    String? authorizationHeader,
  }) {
    final root = Future<CompositionRoot>.value(
      CompositionRoot.forTesting(
        authenticateRequest: AuthenticateRequest(
          _FakeTokenVerifier(verifierResult),
        ),
      ),
    );

    final request = _MockRequest();
    when(() => request.headers).thenReturn({
      if (authorizationHeader != null)
        HttpHeaders.authorizationHeader: authorizationHeader,
    });

    final provided = <AuthenticatedUser>[];
    final downstreamContext = _MockRequestContext();

    final context = _MockRequestContext();
    when(() => context.request).thenReturn(request);
    when(() => context.read<Future<CompositionRoot>>()).thenAnswer((_) => root);
    when(() => context.provide<AuthenticatedUser>(any())).thenAnswer((inv) {
      final create =
          inv.positionalArguments.first as AuthenticatedUser Function();
      provided.add(create());
      return downstreamContext;
    });

    return (context: context, provided: provided);
  }

  /// A terminal handler that records it ran and returns 200.
  ({Handler handler, List<bool> ran}) _okHandler() {
    final ran = <bool>[];
    Response handler(RequestContext _) {
      ran.add(true);
      return Response(body: 'ok');
    }

    return (handler: handler, ran: ran);
  }

  group('bearerAuth middleware', () {
    test('passes a valid token through and provides the principal', () async {
      final wired = _wire(
        verifierResult: Result.ok(_principal()),
        authorizationHeader: 'Bearer good-token',
      );
      final downstream = _okHandler();
      final guarded = bearerAuth()(downstream.handler);

      final response = await guarded(wired.context);

      expect(response.statusCode, HttpStatus.ok);
      expect(downstream.ran, [true]);
      expect(wired.provided.single.userId.value, _uuid);
    });

    test('rejects a missing Authorization header with 401', () async {
      final wired = _wire(verifierResult: Result.ok(_principal()));
      final downstream = _okHandler();
      final guarded = bearerAuth()(downstream.handler);

      final response = await guarded(wired.context);

      expect(response.statusCode, HttpStatus.unauthorized);
      // The protected handler must never run for an unauthenticated request.
      expect(downstream.ran, isEmpty);
    });

    test('rejects an invalid token with 401', () async {
      final wired = _wire(
        verifierResult: const Result.err(
          AppError.authorization('auth.token_invalid', 'bad'),
        ),
        authorizationHeader: 'Bearer bad-token',
      );
      final downstream = _okHandler();
      final guarded = bearerAuth()(downstream.handler);

      final response = await guarded(wired.context);

      expect(response.statusCode, HttpStatus.unauthorized);
      expect(downstream.ran, isEmpty);
    });

    test('maps a transient verification failure to 503, not 401', () async {
      final wired = _wire(
        verifierResult: const Result.err(
          AppError.transient('auth.jwks_fetch_failed', 'unreachable'),
        ),
        authorizationHeader: 'Bearer any',
      );
      final downstream = _okHandler();
      final guarded = bearerAuth()(downstream.handler);

      final response = await guarded(wired.context);

      expect(response.statusCode, HttpStatus.serviceUnavailable);
      expect(downstream.ran, isEmpty);
    });
  });
}
