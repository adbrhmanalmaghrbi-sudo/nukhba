import 'package:infrastructure/infrastructure.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

void main() {
  group('AuthConfig.fromEnv', () {
    test('derives issuer and JWKS URI from the project ref', () {
      final result = AuthConfig.fromEnv(const {
        'NUKHBA_SUPABASE_PROJECT_REF': 'abcdefghijklmnop',
      });

      final config = (result as Ok<AuthConfig>).value;
      expect(
        config.expectedIssuer,
        'https://abcdefghijklmnop.supabase.co/auth/v1',
      );
      expect(
        config.jwksUri.toString(),
        'https://abcdefghijklmnop.supabase.co/auth/v1/.well-known/jwks.json',
      );
      // Default audience for signed-in Supabase users.
      expect(config.expectedAudience, 'authenticated');
      // No legacy secret provided => ES256-only.
      expect(config.hasLegacySecret, isFalse);
      expect(config.legacyHs256Secret, isNull);
    });

    test('honours an explicit audience override', () {
      final result = AuthConfig.fromEnv(const {
        'NUKHBA_SUPABASE_PROJECT_REF': 'abcdefghijklmnop',
        'NUKHBA_SUPABASE_JWT_AUD': 'my-service',
      });
      expect((result as Ok<AuthConfig>).value.expectedAudience, 'my-service');
    });

    test('enables the HS256 fallback when a legacy secret is present', () {
      final result = AuthConfig.fromEnv(const {
        'NUKHBA_SUPABASE_PROJECT_REF': 'abcdefghijklmnop',
        'NUKHBA_SUPABASE_JWT_SECRET': 'super-secret',
      });
      final config = (result as Ok<AuthConfig>).value;
      expect(config.hasLegacySecret, isTrue);
      expect(config.legacyHs256Secret, 'super-secret');
    });

    test('rejects a missing project ref with a validation error', () {
      final result = AuthConfig.fromEnv(const {});
      expect((result as Err<AuthConfig>).error.kind, ErrorKind.validation);
      expect(result.error.code, 'config.supabase_ref');
    });

    test('rejects an empty project ref', () {
      final result = AuthConfig.fromEnv(const {
        'NUKHBA_SUPABASE_PROJECT_REF': '',
      });
      expect((result as Err<AuthConfig>).error.code, 'config.supabase_ref');
    });

    test('rejects a malformed project ref (illegal characters)', () {
      final result = AuthConfig.fromEnv(const {
        'NUKHBA_SUPABASE_PROJECT_REF': 'Bad Ref!',
      });
      expect(
        (result as Err<AuthConfig>).error.code,
        'config.supabase_ref_malformed',
      );
    });
  });

  group('AuthConfig.allowsAlgorithm (server-owned allow-list)', () {
    AuthConfig configWith({String? secret}) {
      final result = AuthConfig.fromEnv({
        'NUKHBA_SUPABASE_PROJECT_REF': 'abcdefghijklmnop',
        if (secret != null) 'NUKHBA_SUPABASE_JWT_SECRET': secret,
      });
      return (result as Ok<AuthConfig>).value;
    }

    test('always allows ES256 (the primary path)', () {
      expect(configWith().allowsAlgorithm('ES256'), isTrue);
      expect(configWith(secret: 's').allowsAlgorithm('ES256'), isTrue);
    });

    test('allows HS256 only when a legacy secret is configured', () {
      expect(configWith().allowsAlgorithm('HS256'), isFalse);
      expect(configWith(secret: 's').allowsAlgorithm('HS256'), isTrue);
    });

    test('never allows alg:none', () {
      expect(configWith().allowsAlgorithm('none'), isFalse);
      expect(configWith(secret: 's').allowsAlgorithm('none'), isFalse);
    });

    test('rejects algorithms outside the allow-list', () {
      for (final alg in const [
        'RS256',
        'HS384',
        'ES384',
        'PS256',
        '',
        'ES256 ',
      ]) {
        expect(
          configWith(secret: 's').allowsAlgorithm(alg),
          isFalse,
          reason: '$alg must not be accepted',
        );
      }
    });
  });
}
