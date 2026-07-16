import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// Port that turns a raw bearer token into a verified [AuthenticatedUser]
/// (Application ADR, Section 9: repository/port pattern; Security ADR,
/// Section 2: the token is verified server-side before mapping to the domain).
///
/// The concrete implementation lives in Infrastructure
/// (`SupabaseJwtVerifier`). The application depends only on this interface, so
/// use-cases can be tested against an in-memory fake with no crypto or network.
///
/// Contract for implementations:
/// * MUST assert signature, expiry, issuer, and audience before returning `Ok`.
/// * MUST map failures to the correct [ErrorKind]:
///   - malformed/expired/invalid-claim token  -> [ErrorKind.authorization]
///   - inability to *reach* verification material (e.g. JWKS fetch failed)
///     -> [ErrorKind.transient] (safe for the caller to retry).
/// * MUST NOT throw; every outcome is a typed [Result].
abstract interface class TokenVerifier {
  /// Verifies [bearerToken] (the raw credential, without the `Bearer ` prefix)
  /// and returns the established principal, or a typed error.
  Future<Result<AuthenticatedUser>> verify(String bearerToken);
}
