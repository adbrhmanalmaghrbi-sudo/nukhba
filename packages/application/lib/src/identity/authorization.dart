import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// The first of the two authorization layers (Security ADR, Section 2:
/// role/permission layer, then a slot for business-invariant checks that arrive
/// with later domain phases).
///
/// This layer answers "does this principal hold sufficient *platform* authority
/// to attempt the action?" — deliberately coarse and context-free. The second
/// layer (business invariants: is the round open? is the caller a member of
/// this group?) is enforced inside the individual domain use-cases that later
/// phases add, not here.
///
/// Pure and total: returns a typed [Result], never throws.
final class Authorization {
  const Authorization._();

  /// Requires that [principal] holds at least the [required] platform role.
  ///
  /// Returns `Ok(principal)` when authorized (so it composes in a use-case
  /// pipeline), or an [ErrorKind.authorization] error otherwise. Role hierarchy
  /// (admin ⊇ user, service ⊇ all) is defined once on
  /// [AuthenticatedUser.hasRole]; this helper does not duplicate it.
  static Result<AuthenticatedUser> requireRole(
    AuthenticatedUser principal,
    PlatformRole required,
  ) {
    if (principal.hasRole(required)) {
      return Result.ok(principal);
    }
    return Result.err(
      AppError.authorization(
        'auth.insufficient_role',
        'Requires ${required.name} role',
      ),
    );
  }
}
