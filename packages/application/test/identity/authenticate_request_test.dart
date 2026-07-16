import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

const _uuid = '11111111-2222-3333-4444-555555555555';

/// In-memory [TokenVerifier] fake (Coding Standards ADR, Section 6): records the
/// token it was handed and returns a scripted result. It lets the use-case be
/// tested with no crypto or network.
final class _FakeTokenVerifier implements TokenVerifier {
  _FakeTokenVerifier(this._response);

  final Result<AuthenticatedUser> _response;
  String? lastToken;
  int calls = 0;

  @override
  Future<Result<AuthenticatedUser>> verify(String bearerToken) async {
    calls++;
    lastToken = bearerToken;
    return _response;
  }
}

AuthenticatedUser _principal() => AuthenticatedUser(
  userId: const UserId(_uuid),
  role: PlatformRole.user,
  email: 'a@example.com',
);

void main() {
  group('AuthenticateRequest — header parsing', () {
    test('rejects a null header without calling the verifier', () async {
      final verifier = _FakeTokenVerifier(Result.ok(_principal()));
      final useCase = AuthenticateRequest(verifier);

      final result = await useCase(null);

      expect(
        (result as Err<AuthenticatedUser>).error.kind,
        ErrorKind.authorization,
      );
      expect(result.error.code, 'auth.missing_bearer');
      expect(verifier.calls, 0);
    });

    test('rejects a non-Bearer scheme', () async {
      final verifier = _FakeTokenVerifier(Result.ok(_principal()));
      final useCase = AuthenticateRequest(verifier);

      final result = await useCase('Basic abc123');

      expect(
        (result as Err<AuthenticatedUser>).error.code,
        'auth.missing_bearer',
      );
      expect(verifier.calls, 0);
    });

    test('rejects a Bearer header with an empty token', () async {
      final verifier = _FakeTokenVerifier(Result.ok(_principal()));
      final useCase = AuthenticateRequest(verifier);

      final result = await useCase('Bearer    ');

      expect(
        (result as Err<AuthenticatedUser>).error.code,
        'auth.missing_bearer',
      );
      expect(verifier.calls, 0);
    });

    test('extracts the token case-insensitively and trims it', () async {
      final verifier = _FakeTokenVerifier(Result.ok(_principal()));
      final useCase = AuthenticateRequest(verifier);

      final result = await useCase('bEaReR   the-token   ');

      expect(result.isOk, isTrue);
      expect(verifier.lastToken, 'the-token');
      expect(verifier.calls, 1);
    });
  });

  group('AuthenticateRequest — verifier delegation', () {
    test('returns the principal on a valid token', () async {
      final verifier = _FakeTokenVerifier(Result.ok(_principal()));
      final useCase = AuthenticateRequest(verifier);

      final result = await useCase('Bearer good');

      expect((result as Ok<AuthenticatedUser>).value.userId.value, _uuid);
    });

    test('propagates an expired-token authorization error', () async {
      final verifier = _FakeTokenVerifier(
        const Result.err(
          AppError.authorization('auth.token_expired', 'expired'),
        ),
      );
      final useCase = AuthenticateRequest(verifier);

      final result = await useCase('Bearer stale');

      expect(
        (result as Err<AuthenticatedUser>).error.code,
        'auth.token_expired',
      );
    });

    test('propagates a wrong-audience authorization error', () async {
      final verifier = _FakeTokenVerifier(
        const Result.err(
          AppError.authorization('auth.token_invalid', 'bad aud'),
        ),
      );
      final useCase = AuthenticateRequest(verifier);

      final result = await useCase('Bearer wrongaud');

      expect(
        (result as Err<AuthenticatedUser>).error.kind,
        ErrorKind.authorization,
      );
    });

    test('propagates a wrong-issuer authorization error', () async {
      final verifier = _FakeTokenVerifier(
        const Result.err(
          AppError.authorization('auth.token_invalid', 'bad iss'),
        ),
      );
      final useCase = AuthenticateRequest(verifier);

      final result = await useCase('Bearer wrongiss');

      expect(
        (result as Err<AuthenticatedUser>).error.kind,
        ErrorKind.authorization,
      );
    });

    test('propagates a transient error when verification material is '
        'unreachable', () async {
      final verifier = _FakeTokenVerifier(
        const Result.err(
          AppError.transient('auth.jwks_fetch_failed', 'unreachable'),
        ),
      );
      final useCase = AuthenticateRequest(verifier);

      final result = await useCase('Bearer any');

      expect(
        (result as Err<AuthenticatedUser>).error.kind,
        ErrorKind.transient,
      );
    });
  });
}
