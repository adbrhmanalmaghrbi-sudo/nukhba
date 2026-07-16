import 'package:shared/shared.dart';

/// Immutable Supabase-auth configuration, sourced from environment variables
/// and validated at startup (Security ADR, Section 7: secrets live only in the
/// server env, never in code).
///
/// Verification of a Supabase JWT is done locally in the backend
/// (Version-Verification log, 2026-07-09): the primary path is asymmetric
/// ES256 via the project's JWKS endpoint; a shared-secret HS256 fallback covers
/// legacy projects that still sign with the project JWT secret.
final class AuthConfig {
  /// Creates a validated auth config.
  const AuthConfig({
    required this.projectRef,
    required this.expectedIssuer,
    required this.expectedAudience,
    required this.jwksUri,
    required this.legacyHs256Secret,
  });

  /// The exhaustive set of JWS `alg` values this backend will EVER honour, as a
  /// server-owned allow-list (Security ADR, Section 2). The verifier consults
  /// this before touching any key material, so an attacker-controlled `alg`
  /// header can never steer verification toward an algorithm the server did not
  /// pre-approve — the standard mitigation for JWT algorithm-confusion / `alg`
  /// substitution (CWE-347). `none` is deliberately absent and therefore always
  /// rejected. HS256 is additionally gated on a configured [legacyHs256Secret].
  static const Set<String> acceptedAlgorithms = {'ES256', 'HS256'};

  /// Builds config from an environment map, returning a typed error rather than
  /// throwing when a required value is missing or malformed.
  ///
  /// Required: `NUKHBA_SUPABASE_PROJECT_REF` (the `<ref>` in
  /// `https://<ref>.supabase.co`). From it the canonical issuer and JWKS URI
  /// are derived, so they cannot drift out of sync.
  ///
  /// Optional:
  /// * `NUKHBA_SUPABASE_JWT_AUD` — expected audience (defaults to
  ///   `authenticated`, the Supabase default for signed-in users).
  /// * `NUKHBA_SUPABASE_JWT_SECRET` — legacy shared secret enabling the HS256
  ///   fallback. Absent on modern (ES256-only) projects.
  static Result<AuthConfig> fromEnv(Map<String, String> env) {
    final ref = env['NUKHBA_SUPABASE_PROJECT_REF'];
    if (ref == null || ref.isEmpty) {
      return const Result.err(
        AppError.validation(
          'config.supabase_ref',
          'NUKHBA_SUPABASE_PROJECT_REF is required',
        ),
      );
    }
    // A Supabase project ref is a lowercase alphanumeric slug; reject anything
    // else early so a typo cannot silently point verification at a bad host.
    if (!_projectRef.hasMatch(ref)) {
      return const Result.err(
        AppError.validation(
          'config.supabase_ref_malformed',
          'NUKHBA_SUPABASE_PROJECT_REF must be a project ref slug',
        ),
      );
    }

    final audience = env['NUKHBA_SUPABASE_JWT_AUD'];
    final legacySecret = env['NUKHBA_SUPABASE_JWT_SECRET'];

    return Result.ok(
      AuthConfig(
        projectRef: ref,
        // Canonical Supabase claims (Version-Verification log): the issuer is
        // the auth base URL; audience defaults to `authenticated`.
        expectedIssuer: 'https://$ref.supabase.co/auth/v1',
        expectedAudience: (audience == null || audience.isEmpty)
            ? 'authenticated'
            : audience,
        jwksUri: Uri.parse(
          'https://$ref.supabase.co/auth/v1/.well-known/jwks.json',
        ),
        legacyHs256Secret: (legacySecret == null || legacySecret.isEmpty)
            ? null
            : legacySecret,
      ),
    );
  }

  /// A Supabase project ref: lowercase letters/digits, typically 20 chars.
  static final RegExp _projectRef = RegExp(r'^[a-z0-9]{8,40}$');

  /// The Supabase project reference (`<ref>` in `<ref>.supabase.co`).
  final String projectRef;

  /// The exact `iss` claim every token must carry.
  final String expectedIssuer;

  /// The exact `aud` claim every token must carry.
  final String expectedAudience;

  /// The project's JWKS endpoint for ES256 public keys.
  final Uri jwksUri;

  /// The legacy shared HS256 secret, or `null` on ES256-only projects. Never
  /// logged.
  final String? legacyHs256Secret;

  /// Whether the HS256 shared-secret fallback is available.
  bool get hasLegacySecret => legacyHs256Secret != null;

  /// Whether [alg] is in the server-owned [acceptedAlgorithms] allow-list AND,
  /// for the HS256 fallback specifically, a legacy secret is actually
  /// configured. This is the single gate the verifier consults before selecting
  /// any key, so the token header can never widen the accepted-algorithm policy.
  bool allowsAlgorithm(String alg) {
    if (!acceptedAlgorithms.contains(alg)) return false;
    if (alg == 'HS256') return hasLegacySecret;
    return true;
  }
}
