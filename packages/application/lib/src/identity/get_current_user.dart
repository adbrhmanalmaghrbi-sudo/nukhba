import 'package:application/src/identity/ports/user_directory.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// Use-case: resolve the canonical platform [User] for an already-verified
/// [AuthenticatedUser] principal, backing the `GET /me` query
/// (Application ADR, Section 2: command/query separation — this is a query).
///
/// Authentication (proving *who* the caller is) has already happened upstream
/// via `AuthenticateRequest`; this use-case answers "what does the platform
/// know about them", ensuring their canonical row exists on first sight so a
/// just-signed-up user is materialized before any later domain phase references
/// them.
///
/// Never throws; returns a typed [Result] whose [ErrorKind] the edge maps to an
/// HTTP status.
final class GetCurrentUser {
  /// Creates the use-case over its [UserDirectory] port.
  const GetCurrentUser(this._directory);

  final UserDirectory _directory;

  /// Resolves the canonical [User] for [principal]. Delegates persistence
  /// concerns entirely to the port; a transient directory failure propagates
  /// as-is so the caller may retry.
  Future<Result<User>> call(AuthenticatedUser principal) {
    return _directory.ensureUser(principal);
  }
}
