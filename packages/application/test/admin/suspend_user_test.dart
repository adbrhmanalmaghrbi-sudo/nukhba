import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import 'fakes.dart';

void main() {
  late InMemoryUserAdminRepository users;
  late InMemoryAuditLogRepository auditLog;
  late SuspendUser suspend;
  late ReinstateUser reinstate;

  setUp(() {
    users = InMemoryUserAdminRepository();
    auditLog = InMemoryAuditLogRepository();
    final recorder = auditRecorderOver(auditLog);
    suspend = SuspendUser(users: users, auditRecorder: recorder);
    reinstate = ReinstateUser(users: users, auditRecorder: recorder);
  });

  final admin = principal(userId: adminUuid);

  group('SuspendUser', () {
    test(
      'suspends an active user, persists it, and records an audit entry',
      () async {
        users.seed(storedUser(id: targetUuid));
        final result = await suspend.call(
          principal: admin,
          targetUserId: targetUuid,
          reason: 'abusive behaviour',
        );
        expect(result.isOk, isTrue);
        expect((result as Ok<User>).value.status, UserStatus.suspended);
        // Persisted.
        expect(users.rowOf(targetUuid)!.status, UserStatus.suspended);
        // Audited: one entry, correct action/actor/target/reason.
        expect(auditLog.rows, hasLength(1));
        final entry = auditLog.rows.single;
        expect(entry.action, AuditAction.userSuspended);
        expect(entry.actorId.value, adminUuid);
        expect(entry.targetRef, targetUuid);
        expect(entry.reason, 'abusive behaviour');
      },
    );

    test(
      'refuses a non-admin caller (authorization) before any state change',
      () async {
        users.seed(storedUser(id: targetUuid));
        final result = await suspend.call(
          principal: principal(userId: adminUuid, role: PlatformRole.user),
          targetUserId: targetUuid,
          reason: 'x',
        );
        expect(result, isA<Err<User>>());
        expect((result as Err<User>).error.kind, ErrorKind.authorization);
        expect(result.error.code, 'auth.insufficient_role');
        // No mutation, no audit.
        expect(users.rowOf(targetUuid)!.status, UserStatus.active);
        expect(auditLog.rows, isEmpty);
      },
    );

    test(
      'refuses a blank reason (validation) before any state change',
      () async {
        users.seed(storedUser(id: targetUuid));
        final result = await suspend.call(
          principal: admin,
          targetUserId: targetUuid,
          reason: '   ',
        );
        expect(
          (result as Err<User>).error.code,
          'admin.sanction_reason_required',
        );
        expect(users.rowOf(targetUuid)!.status, UserStatus.active);
        expect(auditLog.rows, isEmpty);
      },
    );

    test('refuses a null reason', () async {
      users.seed(storedUser(id: targetUuid));
      final result = await suspend.call(
        principal: admin,
        targetUserId: targetUuid,
        reason: null,
      );
      expect(
        (result as Err<User>).error.code,
        'admin.sanction_reason_required',
      );
    });

    test('rejects a malformed target id (validation)', () async {
      final result = await suspend.call(
        principal: admin,
        targetUserId: 'not-a-uuid',
        reason: 'x',
      );
      expect((result as Err<User>).error.kind, ErrorKind.validation);
      expect(result.error.code, 'identity.user_id_malformed');
    });

    test('reports not-found for an absent target (no oracle)', () async {
      final result = await suspend.call(
        principal: admin,
        targetUserId: targetUuid,
        reason: 'x',
      );
      expect((result as Err<User>).error.code, 'admin.user_not_found');
      expect(auditLog.rows, isEmpty);
    });

    test(
      'refuses to suspend a service principal (domain invariant), no audit',
      () async {
        users.seed(storedUser(id: targetUuid, role: PlatformRole.service));
        final result = await suspend.call(
          principal: admin,
          targetUserId: targetUuid,
          reason: 'x',
        );
        expect(
          (result as Err<User>).error.code,
          'identity.cannot_suspend_service',
        );
        expect(auditLog.rows, isEmpty);
      },
    );

    test('is idempotent: re-suspending an already-suspended user succeeds and '
        'still records the (second) audit entry', () async {
      users.seed(storedUser(id: targetUuid, status: UserStatus.suspended));
      final result = await suspend.call(
        principal: admin,
        targetUserId: targetUuid,
        reason: 'again',
      );
      expect(result.isOk, isTrue);
      expect((result as Ok<User>).value.status, UserStatus.suspended);
      // A repeated sanction is still an audited admin action.
      expect(auditLog.rows, hasLength(1));
    });

    test('propagates a transient persist failure without auditing', () async {
      users.seed(storedUser(id: targetUuid));
      users.failNextWith(
        const AppError.transient('db.down', 'temporarily unavailable'),
      );
      final result = await suspend.call(
        principal: admin,
        targetUserId: targetUuid,
        reason: 'x',
      );
      // findUserById consumes the scripted failure -> transient.
      expect((result as Err<User>).error.kind, ErrorKind.transient);
      expect(auditLog.rows, isEmpty);
    });

    test(
      'propagates a transient audit-write failure (persist already happened)',
      () async {
        users.seed(storedUser(id: targetUuid));
        auditLog.failNextWith(
          const AppError.transient('db.down', 'temporarily unavailable'),
        );
        final result = await suspend.call(
          principal: admin,
          targetUserId: targetUuid,
          reason: 'x',
        );
        expect((result as Err<User>).error.kind, ErrorKind.transient);
        // The status change already persisted before the audit attempt.
        expect(users.rowOf(targetUuid)!.status, UserStatus.suspended);
      },
    );
  });

  group('ReinstateUser', () {
    test(
      'reinstates a suspended user, persists it, and audits the reversal',
      () async {
        users.seed(storedUser(id: targetUuid, status: UserStatus.suspended));
        final result = await reinstate.call(
          principal: admin,
          targetUserId: targetUuid,
          reason: 'appeal upheld',
        );
        expect(result.isOk, isTrue);
        expect((result as Ok<User>).value.status, UserStatus.active);
        expect(users.rowOf(targetUuid)!.status, UserStatus.active);
        expect(auditLog.rows.single.action, AuditAction.userReinstated);
        expect(auditLog.rows.single.reason, 'appeal upheld');
      },
    );

    test(
      'reinstate does NOT gate on role: a suspended admin is reinstated',
      () async {
        users.seed(
          storedUser(
            id: targetUuid,
            role: PlatformRole.admin,
            status: UserStatus.suspended,
          ),
        );
        final result = await reinstate.call(
          principal: admin,
          targetUserId: targetUuid,
          reason: 'x',
        );
        expect((result as Ok<User>).value.status, UserStatus.active);
      },
    );

    test('is idempotent on an already-active user', () async {
      users.seed(storedUser(id: targetUuid));
      final result = await reinstate.call(
        principal: admin,
        targetUserId: targetUuid,
        reason: 'x',
      );
      expect(result.isOk, isTrue);
      expect((result as Ok<User>).value.status, UserStatus.active);
    });

    test('refuses a non-admin caller', () async {
      users.seed(storedUser(id: targetUuid, status: UserStatus.suspended));
      final result = await reinstate.call(
        principal: principal(userId: adminUuid, role: PlatformRole.user),
        targetUserId: targetUuid,
        reason: 'x',
      );
      expect((result as Err<User>).error.code, 'auth.insufficient_role');
    });

    test('requires a reason', () async {
      users.seed(storedUser(id: targetUuid, status: UserStatus.suspended));
      final result = await reinstate.call(
        principal: admin,
        targetUserId: targetUuid,
        reason: '',
      );
      expect(
        (result as Err<User>).error.code,
        'admin.sanction_reason_required',
      );
    });
  });
}
