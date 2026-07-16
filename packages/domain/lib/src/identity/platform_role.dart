import 'package:shared/shared.dart';

/// A platform-wide role, the coarse first layer of the two-layer authorization
/// model (Security ADR, Section 2: role/permission layer, then business
/// invariants). This is *platform* authority, deliberately distinct from any
/// per-group role that later social phases introduce.
///
/// The set is closed: an unknown role string from a token is a validation
/// failure, never silently coerced (Security ADR, Section 2: the client is
/// untrusted; claims are validated).
enum PlatformRole {
  /// A standard end user. The default authority for any authenticated
  /// principal that carries no elevated platform role.
  user,

  /// A platform administrator (admin console, moderation, operations).
  admin,

  /// A trusted machine principal (internal service-to-service calls). Never
  /// issued to a human session.
  service;

  /// Parses a [PlatformRole] from an untrusted claim [raw].
  ///
  /// Returns a validation [AppError] rather than throwing, so a malformed or
  /// unrecognized role in a verified token is surfaced as a typed failure on
  /// the auth path. An absent role is *not* accepted here; callers that want a
  /// default should use [fromClaimOrUser].
  static Result<PlatformRole> tryParse(String? raw) {
    switch (raw) {
      case 'user':
        return const Result.ok(PlatformRole.user);
      case 'admin':
        return const Result.ok(PlatformRole.admin);
      case 'service':
        return const Result.ok(PlatformRole.service);
      default:
        return Result.err(
          AppError.validation(
            'identity.role_unknown',
            'Unknown platform role: ${raw ?? '<null>'}',
          ),
        );
    }
  }

  /// Resolves a platform role from an optional claim, defaulting to [user] when
  /// the claim is absent or blank.
  ///
  /// Supabase's own `role` claim (`authenticated`, `anon`, `service_role`) is
  /// an *authentication* signal, not our platform-authority model; the verifier
  /// maps it to a [PlatformRole] before this is consulted. A present-but-unknown
  /// value is still a validation failure (via [tryParse]); only a truly missing
  /// value falls back to [user].
  static Result<PlatformRole> fromClaimOrUser(String? raw) {
    if (raw == null || raw.isEmpty) {
      return const Result.ok(PlatformRole.user);
    }
    return tryParse(raw);
  }
}
