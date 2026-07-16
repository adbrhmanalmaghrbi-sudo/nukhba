import 'dart:convert';
import 'dart:typed_data';

import 'package:application/application.dart';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:domain/domain.dart';
import 'package:infrastructure/src/identity/auth_config.dart';
import 'package:infrastructure/src/identity/jwks_client.dart';
import 'package:pointycastle/ecc/api.dart' as pc;
import 'package:pointycastle/ecc/curves/prime256v1.dart';
import 'package:shared/shared.dart';

/// Local Supabase JWT verifier (Security ADR, Section 2; Version-Verification
/// log, 2026-07-09).
///
/// Verifies Supabase-issued access tokens entirely in-process — no network call
/// per request except an occasional JWKS refresh:
/// * Primary path: asymmetric **ES256** using the project's published JWKS,
///   selected by the token header `kid` (the Supabase default since
///   2025-10-01).
/// * Fallback path: shared-secret **HS256** for legacy projects, enabled only
///   when [AuthConfig.legacyHs256Secret] is configured.
///
/// Every accepted token has its signature, `exp`, `iss`, and `aud` asserted by
/// `JWT.verify`. Failures are mapped to typed [Result]s with the correct
/// [ErrorKind]: bad/expired tokens are [ErrorKind.authorization] (terminal);
/// an unreachable JWKS endpoint is [ErrorKind.transient] (retryable). Nothing
/// throws out of [verify].
///
/// API verified against `dart_jsonwebtoken` 2.17.0 (2026-07-09):
///   * `JWT.decode(token)` exposes `.header` (`alg`, `kid`) without verifying.
///   * `JWTKey.fromJWK(Map<String,dynamic>)` builds an `ECPublicKey` from an EC
///     JWK; throws `JWTParseException` on invalid/unsupported keys.
///   * `JWT.verify(token, key, {audience: Audience, issuer, subject})` asserts
///     signature/exp/iss/aud and throws `JWTExpiredException` /
///     `JWTInvalidException` / `JWTException` on failure.
final class SupabaseJwtVerifier implements TokenVerifier {
  /// Creates a verifier over [config] and a [JwksClient].
  const SupabaseJwtVerifier(this._config, this._jwks);

  final AuthConfig _config;
  final JwksClient _jwks;

  @override
  Future<Result<AuthenticatedUser>> verify(String bearerToken) async {
    // 1. Decode (unverified) to read the header and choose a verification path.
    final JWT decoded;
    try {
      decoded = JWT.decode(bearerToken);
    } on Object {
      return const Result.err(
        AppError.authorization('auth.malformed_token', 'Malformed token'),
      );
    }

    final header = decoded.header;
    final alg = header?['alg'] as String?;
    if (alg == null) {
      return const Result.err(
        AppError.authorization('auth.missing_alg', 'Token header missing alg'),
      );
    }

    // Server-owned algorithm allow-list check, BEFORE any key material is
    // touched. The `alg` header is attacker-controlled; gating on the config's
    // allow-list here is the primary mitigation for algorithm-confusion / `alg`
    // substitution (CWE-347). This also rejects `alg: none` and any algorithm
    // outside {ES256, (HS256 when a legacy secret is configured)}.
    if (!_config.allowsAlgorithm(alg)) {
      return Result.err(
        AppError.authorization(
          'auth.unsupported_alg',
          'Token algorithm is not accepted: $alg',
        ),
      );
    }

    // 2. Resolve the verification key for the declared (now allow-listed) alg.
    final keyResult = await _keyFor(alg, header?['kid'] as String?);
    if (keyResult is Err<JWTKey>) return Result.err(keyResult.error);
    final key = (keyResult as Ok<JWTKey>).value;

    // 3. Verify signature + registered claims (exp/iss/aud) in one call.
    final JWT verified;
    try {
      verified = JWT.verify(
        bearerToken,
        key,
        // Enforce the `typ: JWT` header (library default; pinned explicitly so
        // the intent survives any future library default change) and the
        // `exp` / `nbf` temporal claims, alongside iss/aud below.
        checkHeaderType: true,
        checkExpiresIn: true,
        checkNotBefore: true,
        issuer: _config.expectedIssuer,
        audience: Audience.one(_config.expectedAudience),
      );
    } on JWTExpiredException {
      return const Result.err(
        AppError.authorization('auth.token_expired', 'Token has expired'),
      );
    } on JWTException catch (e) {
      // Covers invalid signature, wrong iss/aud, not-yet-valid, parse errors.
      return Result.err(
        AppError.authorization(
          'auth.token_invalid',
          'Token is invalid: '
              '${e.message}',
        ),
      );
    }

    // 4. Map verified claims to the domain principal.
    return _principalFrom(verified);
  }

  /// Chooses and materializes the verification key for [alg].
  Future<Result<JWTKey>> _keyFor(String alg, String? kid) async {
    switch (alg) {
      case 'ES256':
        final jwkResult = await _jwks.keyForKid(kid);
        if (jwkResult is Err<Jwk>) return Result.err(jwkResult.error);
        final jwk = (jwkResult as Ok<Jwk>).value;
        try {
          return Result.ok(_ecPublicKeyFromJwk(jwk.raw));
        } on Object {
          return const Result.err(
            AppError.authorization(
              'auth.jwk_unusable',
              'JWKS key could not be parsed',
            ),
          );
        }
      case 'HS256':
        final secret = _config.legacyHs256Secret;
        if (secret == null) {
          // Unreachable in practice: `allowsAlgorithm('HS256')` already required
          // a configured secret upstream. Kept as a defensive backstop so the
          // branch can never dereference a null secret even if the gate changes.
          return const Result.err(
            AppError.authorization(
              'auth.hs256_disabled',
              'HS256 tokens are not accepted by this project',
            ),
          );
        }
        return Result.ok(SecretKey(secret));
      default:
        return Result.err(
          AppError.authorization(
            'auth.unsupported_alg',
            'Unsupported token algorithm: $alg',
          ),
        );
    }
  }

  /// Extracts a validated [AuthenticatedUser] from a verified token's payload.
  Result<AuthenticatedUser> _principalFrom(JWT verified) {
    final payload = verified.payload;
    if (payload is! Map) {
      return const Result.err(
        AppError.authorization('auth.no_claims', 'Token has no claims object'),
      );
    }
    final claims = payload.cast<String, dynamic>();

    final idResult = UserId.tryParse(claims['sub'] as String?);
    if (idResult is Err<UserId>) {
      return Result.err(
        AppError.authorization(idResult.error.code, idResult.error.message),
      );
    }
    final userId = (idResult as Ok<UserId>).value;

    // Supabase's `role` claim is an authentication signal
    // (`authenticated` / `anon` / `service_role`), NOT our platform authority
    // model. Map it explicitly; anything human-facing is `PlatformRole.user`,
    // and `service_role` is the trusted machine principal. Elevation to `admin`
    // is a platform decision owned by the directory, never taken from a token.
    final platformRole = _mapSupabaseRole(claims['role'] as String?);

    return Result.ok(
      AuthenticatedUser(
        userId: userId,
        role: platformRole,
        email: claims['email'] as String?,
      ),
    );
  }

  /// Maps a Supabase `role` claim to a [PlatformRole]. Unknown or absent values
  /// default to [PlatformRole.user]; only `service_role` grants the service
  /// principal.
  static PlatformRole _mapSupabaseRole(String? supabaseRole) {
    return supabaseRole == 'service_role'
        ? PlatformRole.service
        : PlatformRole.user;
  }

  /// Materializes a `dart_jsonwebtoken` [ECPublicKey] from a raw EC JWK.
  ///
  /// `dart_jsonwebtoken` 2.17.0 has no `JWTKey.fromJWK`; its [ECPublicKey]
  /// builds only from PEM/bytes. Supabase publishes P-256 (`crv: "P-256"`,
  /// `kty: "EC"`) JWKs with base64url-encoded affine coordinates `x`/`y`, so we
  /// reconstruct the curve point via PointyCastle and wrap it with
  /// [ECPublicKey.raw]. Throws on any shape/curve mismatch — the single caller
  /// catches [Object] and maps it to `auth.jwk_unusable`.
  static ECPublicKey _ecPublicKeyFromJwk(Map<String, dynamic> jwk) {
    if (jwk['kty'] != 'EC' || jwk['crv'] != 'P-256') {
      throw const FormatException('Unsupported JWK: expected EC/P-256');
    }
    final xBytes = _base64UrlDecode(jwk['x'] as String);
    final yBytes = _base64UrlDecode(jwk['y'] as String);
    final domain = ECCurve_prime256v1();
    final x = _bytesToBigInt(xBytes);
    final y = _bytesToBigInt(yBytes);
    final point = domain.curve.createPoint(x, y);
    return ECPublicKey.raw(pc.ECPublicKey(point, domain));
  }

  /// Decodes an unpadded base64url string (JWK coordinate encoding, RFC 7518).
  static Uint8List _base64UrlDecode(String input) {
    final normalized = base64Url.normalize(input);
    return base64Url.decode(normalized);
  }

  /// Reads a big-endian unsigned byte array as a [BigInt].
  static BigInt _bytesToBigInt(Uint8List bytes) {
    var result = BigInt.zero;
    for (final byte in bytes) {
      result = (result << 8) | BigInt.from(byte);
    }
    return result;
  }
}
