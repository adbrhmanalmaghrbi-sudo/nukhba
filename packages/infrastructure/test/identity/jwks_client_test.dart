import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:infrastructure/infrastructure.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

final _jwksUri = Uri.parse('https://ref.supabase.co/auth/v1/jwks');

/// Builds a JWKS JSON body with the given key ids (minimal EC key shape; the
/// client only needs `kid` for selection — it hands the raw map to the verifier
/// untouched).
String _jwksBody(List<String> kids) => jsonEncode({
  'keys': [
    for (final kid in kids)
      {
        'kty': 'EC',
        'crv': 'P-256',
        'kid': kid,
        'x': 'x-$kid',
        'y': 'y-$kid',
        'alg': 'ES256',
      },
  ],
});

void main() {
  group('JwksClient.keyForKid', () {
    test('fetches once, then serves subsequent lookups from cache', () async {
      var fetches = 0;
      final client = JwksClient(
        _jwksUri,
        httpClient: MockClient((_) async {
          fetches++;
          return http.Response(_jwksBody(['k1', 'k2']), 200);
        }),
      );

      final first = await client.keyForKid('k1');
      final second = await client.keyForKid('k2');

      expect((first as Ok<Jwk>).value.kid, 'k1');
      expect((second as Ok<Jwk>).value.kid, 'k2');
      // Both keys came from a single network fetch (cache hit for the second).
      expect(fetches, 1);
    });

    test('forces exactly one refresh on an unknown kid (rotation)', () async {
      var fetches = 0;
      final client = JwksClient(
        _jwksUri,
        // Second fetch returns a rotated-in key set that includes `k2`.
        httpClient: MockClient((_) async {
          fetches++;
          final kids = fetches == 1 ? ['k1'] : ['k1', 'k2'];
          return http.Response(_jwksBody(kids), 200);
        }),
        // Allow the forced refresh to run without rate-limiting.
        minRefreshInterval: Duration.zero,
      );

      final miss = await client.keyForKid('k2');

      expect((miss as Ok<Jwk>).value.kid, 'k2');
      // One initial fetch (stale cache) + one forced refresh for the miss.
      expect(fetches, 2);
    });

    test('returns authorization no_matching_key when the kid never '
        'appears', () async {
      final client = JwksClient(
        _jwksUri,
        httpClient: MockClient((_) async {
          return http.Response(_jwksBody(['k1']), 200);
        }),
        // Allow the forced refresh to run without rate-limiting.
        minRefreshInterval: Duration.zero,
      );

      final result = await client.keyForKid('nope');

      expect((result as Err<Jwk>).error.kind, ErrorKind.authorization);
      expect(result.error.code, 'auth.no_matching_key');
    });

    test('maps a non-200 JWKS response to a transient error', () async {
      final client = JwksClient(
        _jwksUri,
        httpClient: MockClient((_) async => http.Response('nope', 503)),
      );

      final result = await client.keyForKid('k1');

      expect((result as Err<Jwk>).error.kind, ErrorKind.transient);
      expect(result.error.code, 'auth.jwks_status');
    });

    test('maps a network failure to a transient error', () async {
      final client = JwksClient(
        _jwksUri,
        httpClient: MockClient((_) async => throw const _NetworkDown()),
      );

      final result = await client.keyForKid('k1');

      expect((result as Err<Jwk>).error.kind, ErrorKind.transient);
      expect(result.error.code, 'auth.jwks_fetch_failed');
    });

    test('resolves a null kid when exactly one key is published', () async {
      final client = JwksClient(
        _jwksUri,
        httpClient: MockClient(
          (_) async => http.Response(_jwksBody(['only']), 200),
        ),
      );

      final result = await client.keyForKid(null);
      expect((result as Ok<Jwk>).value.kid, 'only');
    });

    test('refetches after the TTL expires', () async {
      var fetches = 0;
      var now = DateTime(2026);
      final client = JwksClient(
        _jwksUri,
        httpClient: MockClient((_) async {
          fetches++;
          return http.Response(_jwksBody(['k1']), 200);
        }),
        now: () => now,
        ttl: const Duration(minutes: 10),
      );

      await client.keyForKid('k1');
      // Advance past the TTL; the next lookup must refetch.
      now = now.add(const Duration(minutes: 11));
      await client.keyForKid('k1');

      expect(fetches, 2);
    });
  });
}

/// A stand-in network exception for the failure-path test.
final class _NetworkDown implements Exception {
  const _NetworkDown();
}
