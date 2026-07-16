import 'package:application/src/admin/audit_recorder.dart';
import 'package:application/src/admin/ports/user_admin_repository.dart';
import 'package:application/src/identity/authorization.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// Command use-cases for the reversible admin user sanction — `SuspendUser` and
/// its mirror `ReinstateUser` (Admin Panel decision OPEN-A #1: a simple
/// suspend/reinstate pair, no temporary-vs-permanent distinction in v1, every
/// action carrying a mandatory reason).
///
/// This is the ONE genuinely-new domain capability of the phase: the domain
/// already shipped the `UserStatus.suspended` hook + the pure
/// `User.suspend()`/`reinstate()` transitions, but no use-case drove them
/// (decision §2 #1 / §2 #4-spine). Both use-cases:
/// 1. authorize the caller as [PlatformRole.admin] (Security ADR §2.3, the first
///    mandatory authorization layer — `Authorization.requireRole`);
/// 2. require a non-blank [reason] (decision OPEN-A #1 — a sanction is always
///    justified; the same reason feeds the mandatory audit record, OPEN-B);
/// 3. parse the TARGET user id and resolve the user (a `null`/absent user is a
///    typed not-found — never leaking whether the id belongs to anyone);
/// 4. apply the pure domain transition (`User.suspend()` refuses a `service`
///    principal — `identity.cannot_suspend_service`; both transitions are
///    idempotent, so a repeated sanction converges without error);
/// 5. persist the transition via [UserAdminRepository.updateUser];
/// 6. record an immutable [AuditEntry] via [AuditRecorder] (the sanction is not
///    complete without its attributable trace — Security ADR §2.4). The audit
///    is written AFTER a successful persist so the trail never records a
///    sanction that did not take effect; an audit-write failure propagates
///    (the crown-jewel action is not silently untraceable).
///
/// Never throws; returns the sanctioned [User] (its new status) as a typed
/// [Result].
final class SuspendUser {
  /// Creates the use-case over its collaborators.
  const SuspendUser({
    required UserAdminRepository users,
    required AuditRecorder auditRecorder,
  }) : _users = users,
       _audit = auditRecorder;

  final UserAdminRepository _users;
  final AuditRecorder _audit;

  /// Suspends the user [targetUserId] on behalf of the admin [principal], with
  /// the mandatory [reason].
  Future<Result<User>> call({
    required AuthenticatedUser principal,
    required String targetUserId,
    required String? reason,
  }) {
    return _transition(
      principal: principal,
      targetUserId: targetUserId,
      reason: reason,
      action: AuditAction.userSuspended,
      apply: (user) => user.suspend(),
    );
  }

  Future<Result<User>> _transition({
    required AuthenticatedUser principal,
    required String targetUserId,
    required String? reason,
    required AuditAction action,
    required Result<User> Function(User user) apply,
  }) async {
    // 1. Admin authority (role/permission layer — Security ADR §2.3).
    final auth = Authorization.requireRole(principal, PlatformRole.admin);
    if (auth is Err<AuthenticatedUser>) {
      return Result.err(auth.error);
    }

    // 2. Mandatory sanction reason (decision OPEN-A #1) — validated here so a
    //    blank body is refused before any state is touched.
    final reasonResult = _requireReason(reason);
    if (reasonResult is Err<String>) {
      return Result.err(reasonResult.error);
    }
    final trimmedReason = (reasonResult as Ok<String>).value;

    // 3. Parse + resolve the target user.
    final idResult = UserId.tryParse(targetUserId);
    if (idResult is Err<UserId>) {
      return Result.err(idResult.error);
    }
    final targetId = (idResult as Ok<UserId>).value;

    final found = await _users.findUserById(targetId);
    if (found is Err<User?>) {
      return Result.err(found.error);
    }
    final user = (found as Ok<User?>).value;
    if (user == null) {
      return const Result.err(
        AppError.invariant('admin.user_not_found', 'No such user to sanction'),
      );
    }

    // 4. Apply the pure domain transition (refuses service; idempotent).
    final transitioned = apply(user);
    if (transitioned is Err<User>) {
      return Result.err(transitioned.error);
    }
    final next = (transitioned as Ok<User>).value;

    // 5. Persist.
    final saved = await _users.updateUser(next);
    if (saved is Err<User>) {
      return Result.err(saved.error);
    }
    final storedUser = (saved as Ok<User>).value;

    // 6. Record the immutable audit trace (after a successful persist).
    final audit = await _audit.record(
      actorId: principal.userId,
      action: action,
      targetRef: targetId.value,
      reason: trimmedReason,
    );
    if (audit is Err<AuditEntry>) {
      return Result.err(audit.error);
    }

    return Result.ok(storedUser);
  }

  static Result<String> _requireReason(String? reason) {
    final trimmed = reason?.trim() ?? '';
    if (trimmed.isEmpty) {
      return const Result.err(
        AppError.validation(
          'admin.sanction_reason_required',
          'A suspend/reinstate action requires a non-blank reason',
        ),
      );
    }
    return Result.ok(trimmed);
  }
}

/// The mirror of [SuspendUser]: reverses a suspension (`User.reinstate()`).
/// Same admin gate + mandatory reason + audit discipline; the transition never
/// gates on role (a suspended admin can be reinstated).
final class ReinstateUser {
  /// Creates the use-case over its collaborators.
  ///
  /// Not a `const` constructor: the delegated `SuspendUser(...)` is built from
  /// the runtime collaborator arguments, so the initializer is not a compile-
  /// time constant expression.
  ReinstateUser({
    required UserAdminRepository users,
    required AuditRecorder auditRecorder,
  }) : _delegate = SuspendUser(users: users, auditRecorder: auditRecorder);

  final SuspendUser _delegate;

  /// Reinstates the user [targetUserId] on behalf of the admin [principal],
  /// with the mandatory [reason].
  Future<Result<User>> call({
    required AuthenticatedUser principal,
    required String targetUserId,
    required String? reason,
  }) {
    return _delegate._transition(
      principal: principal,
      targetUserId: targetUserId,
      reason: reason,
      action: AuditAction.userReinstated,
      apply: (user) => user.reinstate(),
    );
  }
}
