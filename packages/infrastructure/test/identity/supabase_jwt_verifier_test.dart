import 'dart:convert';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:domain/domain.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:infrastructure/infrastructure.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

const _secret = 'legacy-shared-secret-for-tests-only';
const _ref = 'abcdefghijklmnop';
const _issuer = 'https://$_ref.supabase.co/auth/v1';
const _uuid = '11111111-2222-3333-4444-555555555555';

/// Builds an [AuthConfig] with the HS256 fallback enabled, pointed at a JWKS
/// endpoint that is never actually reached in these HS256-path tests.
AuthConfig _config({String? secret = _secret, String aud = 'authenticated'}) {
  final result = AuthConfig.fromEnv({
    'NUKHBA_SUPABASE_PROJECT_REF': _ref,
    'NUKHBA_SUPABASE_JWT_AUD': aud,
    if (secret != null) 'NUKHBA_SUPABASE_JWT_SECRET': secret,
  });
  return (result as Ok<AuthConfig>).value;
}

/// A JWKS client wired to a client that always fails — proves the HS256 path
/// never touches the network.
JwksClient _unusedJwks() => JwksClient(
  Uri.parse('https://$_ref.supabase.co/auth/v1/jwks'),
  httpClient: MockClient(
    (_) async => http.Response('should not be called', 500),
  ),
);

/// Signs an HS256 token with the given claims for the hermetic verify tests.
String _signHs256({
  String issuer = _issuer,
  String audience = 'authenticated',
  String subject = _uuid,
  String? role = 'authenticated',
  String? email = 'a@example.com',
  Duration? expiresIn = const Duration(minutes: 5),
  String secret = _secret,
}) {
  final jwt = JWT(
    {
      'sub': subject,
      if (role != null) 'role': role,
      if (email != null) 'email': email,
    },
    issuer: issuer,
    audience: Audience.one(audience),
    subject: subject,
  );
  return jwt.sign(
    SecretKey(secret),
    algorithm: JWTAlgorithm.HS256,
    expiresIn: expiresIn,
  );
}

void main() {
  group('SupabaseJwtVerifier (HS256 fallback, hermetic)', () {
    test('verifies a valid token and maps claims to the principal', () async {
      final verifier = SupabaseJwtVerifier(_config(), _unusedJwks());
      final token = _signHs256();

      final result = await verifier.verify(token);

      final principal = (result as Ok<AuthenticatedUser>).value;
      expect(principal.userId.value, _uuid);
      expect(principal.email, 'a@example.com');
      // A Supabase `authenticated` role maps to PlatformRole.user, never admin.
      expect(principal.role, PlatformRole.user);
    });

    test('maps the service_role claim to the service principal', () async {
      final verifier = SupabaseJwtVerifier(_config(), _unusedJwks());
      final token = _signHs256(role: 'service_role');

      final result = await verifier.verify(token);

      expect(
        (result as Ok<AuthenticatedUser>).value.role,
        PlatformRole.service,
      );
    });

    test('rejects an expired token as authorization/token_expired', () async {
      final verifier = SupabaseJwtVerifier(_config(), _unusedJwks());
      final token = _signHs256(expiresIn: const Duration(seconds: -1));

      final result = await verifier.verify(token);

      expect(
        (result as Err<AuthenticatedUser>).error.kind,
        ErrorKind.authorization,
      );
      expect(result.error.code, 'auth.token_expired');
    });

    test('rejects a wrong audience', () async {
      final verifier = SupabaseJwtVerifier(_config(), _unusedJwks());
      final token = _signHs256(audience: 'someone-else');

      final result = await verifier.verify(token);

      expect(
        (result as Err<AuthenticatedUser>).error.kind,
        ErrorKind.authorization,
      );
      expect(result.error.code, 'auth.token_invalid');
    });

    test('rejects a wrong issuer', () async {
      final verifier = SupabaseJwtVerifier(_config(), _unusedJwks());
      final token = _signHs256(issuer: 'https://evil.example.com/auth/v1');

      final result = await verifier.verify(token);

      expect(
        (result as Err<AuthenticatedUser>).error.code,
        'auth.token_invalid',
      );
    });

    test(
      'rejects a token signed with the wrong secret (bad signature)',
      () async {
        final verifier = SupabaseJwtVerifier(_config(), _unusedJwks());
        final token = _signHs256(secret: 'a-different-secret');

        final result = await verifier.verify(token);

        expect(
          (result as Err<AuthenticatedUser>).error.kind,
          ErrorKind.authorization,
        );
      },
    );

    test(
      'rejects HS256 when the project has no legacy secret configured',
      () async {
        // ES256-only project: HS256 tokens must be refused, not accepted. The
        // server-owned allow-list rejects HS256 up front (before any key is
        // touched) because no legacy secret gates it in.
        final verifier = SupabaseJwtVerifier(
          _config(secret: null),
          _unusedJwks(),
        );
        final token = _signHs256();

        final result = await verifier.verify(token);

        final err = (result as Err<AuthenticatedUser>).error;
        expect(err.kind, ErrorKind.authorization);
        expect(err.code, 'auth.unsupported_alg');
      },
    );

    test('rejects a token whose sub is not a UUID', () async {
      final verifier = SupabaseJwtVerifier(_config(), _unusedJwks());
      final token = _signHs256(subject: 'not-a-uuid');

      final result = await verifier.verify(token);

      expect(
        (result as Err<AuthenticatedUser>).error.kind,
        ErrorKind.authorization,
      );
    });

    test('rejects a garbage (non-JWT) token as malformed', () async {
      final verifier = SupabaseJwtVerifier(_config(), _unusedJwks());

      final result = await verifier.verify('not.a.jwt');

      expect(
        (result as Err<AuthenticatedUser>).error.code,
        'auth.malformed_token',
      );
    });
  });

  group('SupabaseJwtVerifier (algorithm-confusion hardening)', () {
    test('rejects alg:none before touching any key material', () async {
      // An attacker strips the signature and sets alg:none. The server-owned
      // allow-list must reject it up front (CWE-347 mitigation).
      final verifier = SupabaseJwtVerifier(_config(), _unusedJwks());
      final token = _tokenWithHeaderAlg('none', signature: '');

      final result = await verifier.verify(token);

      final err = (result as Err<AuthenticatedUser>).error;
      expect(err.kind, ErrorKind.authorization);
      expect(err.code, 'auth.unsupported_alg');
    });

    test('rejects an algorithm outside the allow-list (e.g. RS256)', () async {
      // Even a syntactically valid non-allow-listed alg must be refused before
      // key selection — the token header cannot widen server policy.
      final verifier = SupabaseJwtVerifier(_config(), _unusedJwks());
      final token = _tokenWithHeaderAlg('RS256', signature: 'AAAA');

      final result = await verifier.verify(token);

      expect(
        (result as Err<AuthenticatedUser>).error.code,
        'auth.unsupported_alg',
      );
    });
  });
}

/// Hand-crafts a JWS-shaped token with an arbitrary `alg` header value and an
/// opaque (unverifiable) signature segment, for testing the allow-list gate
/// that runs *before* signature verification.
String _tokenWithHeaderAlg(String alg, {required String signature}) {
  String seg(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final header = seg({'alg': alg, 'typ': 'JWT'});
  final payload = seg({'sub': _uuid, 'iss': _issuer, 'aud': 'authenticated'});
  return '$header.$payload.$signature';
}
