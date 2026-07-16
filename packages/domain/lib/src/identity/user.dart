import 'package:domain/src/identity/platform_role.dart';
import 'package:domain/src/identity/user_id.dart';
import 'package:shared/shared.dart';

/// The lifecycle state of a platform [User].
///
/// Kept minimal for the Authentication phase: later phases (Admin, Social) may
/// extend the domain policies that transition between states, but the closed
/// set is fixed here so authorization can reason about it exhaustively.
enum UserStatus {
  /// The user may authenticate and act on the platform.
  active,

  /// The user is suspended by an administrator; authentication may succeed at
  /// the identity provider, but the platform denies privileged action.
  suspended;

  /// Whether a user in this status is permitted to act (beyond inspecting their
  /// own identity). Suspension is enforced by the application, not the token.
  bool get canAct => this == UserStatus.active;
}

/// The canonical, platform-owned identity of a person or machine principal
/// (Database ADR, Section 3: `User` is the Identity aggregate root).
///
/// Credentials are NOT modeled here: password handling is delegated entirely to
/// Supabase Auth (Security ADR, Section 2; Application ADR, Section 2). This
/// entity is the platform's own projection of that identity — the join point
/// between an external auth subject and everything the domain owns about them.
///
/// Pure: no framework, no IO. Value-comparable by [id] plus its mutable-looking
/// fields (the instance itself is immutable; state changes produce new values).
final class User {
  /// Creates a canonical user.
  const User({
    required this.id,
    required this.email,
    required this.role,
    required this.status,
  });

  /// The platform identity, equal to the Supabase Auth subject UUID.
  final UserId id;

  /// The user's email as known to the identity provider. May be absent for
  /// principals authenticated by other means (e.g. phone-only, service).
  final String? email;

  /// The coarse platform authority (first authorization layer).
  final PlatformRole role;

  /// The lifecycle state governing whether the user may act.
  final UserStatus status;

  /// Whether this user is currently permitted to perform privileged actions.
  /// A [service] principal is always permitted; human users must be [active].
  bool get canAct => role == PlatformRole.service || status.canAct;

  /// Returns a copy with selected fields replaced. Used by directory upserts to
  /// reconcile provider-sourced fields without mutating the original value.
  User copyWith({String? email, PlatformRole? role, UserStatus? status}) {
    return User(
      id: id,
      email: email ?? this.email,
      role: role ?? this.role,
      status: status ?? this.status,
    );
  }

  /// Transitions this user into [UserStatus.suspended] — the reversible
  /// administrator sanction (Admin Panel decision OPEN-A #1: a simple
  /// `suspend`/`reinstate` pair, no temporary-vs-permanent distinction in v1).
  ///
  /// Pure and total: the aggregate reasons only about its own state — the
  /// *authority* to suspend (caller must be a platform admin) and the mandatory
  /// audit reason are enforced by the use-case (`SuspendUser`), not the entity,
  /// mirroring how owner-authority for `Group.rename` lives in the use-case.
  ///
  /// A [service] principal is never a human account and cannot be suspended
  /// (it would silently break internal calls); suspending a `service` user is
  /// refused as an invariant violation. Suspending an already-suspended user is
  /// **idempotent** — it returns an equal value rather than an error, so a
  /// retried sanction converges (mirror of `Notification.markRead`).
  Result<User> suspend() {
    if (role == PlatformRole.service) {
      return const Result.err(
        AppError.invariant(
          'identity.cannot_suspend_service',
          'A service principal cannot be suspended',
        ),
      );
    }
    if (status == UserStatus.suspended) {
      return Result.ok(this);
    }
    return Result.ok(copyWith(status: UserStatus.suspended));
  }

  /// Transitions this user back into [UserStatus.active] — reversing a
  /// suspension (Admin Panel decision OPEN-A #1). The mirror of [suspend]:
  /// pure/total, authority + audit reason enforced in the use-case
  /// (`ReinstateUser`), idempotent when the user is already active.
  Result<User> reinstate() {
    if (status == UserStatus.active) {
      return Result.ok(this);
    }
    return Result.ok(copyWith(status: UserStatus.active));
  }

  @override
  bool operator ==(Object other) =>
      other is User &&
      other.id == id &&
      other.email == email &&
      other.role == role &&
      other.status == status;

  @override
  int get hashCode => Object.hash(id, email, role, status);

  @override
  String toString() =>
      'User(${id.value}, role: ${role.name}, '
      'status: ${status.name})';
}
