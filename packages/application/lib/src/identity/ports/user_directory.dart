import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// Port for resolving the platform's canonical [User] record for a verified
/// principal (Application ADR, Section 9). Backed in Infrastructure by
/// `PostgresUserDirectory`.
///
/// The identity provider (Supabase Auth) owns credentials; the *platform* owns
/// the canonical user row (role, status, and any future domain-owned identity
/// state). This port is the seam between the two: given a principal the token
/// already established, it returns the platform's own record, creating it on
/// first sight ("ensure") so a freshly-signed-up user has a canonical row
/// before any domain phase references them.
///
/// Contract for implementations:
/// * MUST be idempotent: repeated calls for the same principal converge on one
///   row (Application ADR, Section 2: commands are idempotent/safely
///   retryable).
/// * MUST map infrastructure failures to [ErrorKind.transient]; it MUST NOT
///   invent authorization/validation errors — the principal is already
///   verified upstream.
/// * MUST NOT throw; every outcome is a typed [Result].
abstract interface class UserDirectory {
  /// Resolves the canonical [User] for [principal], creating the row on first
  /// sight and reconciling provider-sourced fields (email) on subsequent calls.
  ///
  /// The stored [PlatformRole] and [UserStatus] are the platform's own record
  /// and are authoritative over token claims once the row exists; a newly
  /// created row is seeded with the principal's token role and
  /// [UserStatus.active].
  Future<Result<User>> ensureUser(AuthenticatedUser principal);
}
