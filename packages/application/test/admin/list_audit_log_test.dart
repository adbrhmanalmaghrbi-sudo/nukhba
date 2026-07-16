import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import 'fakes.dart';

/// Builds a stored [AuditEntry] directly (bypassing the recorder) so a test can
/// seed the trail with a controlled `occurredAt`/id and assert ordering.
AuditEntry _seedEntry({
  required String id,
  required AuditAction action,
  required String targetRef,
  required DateTime occurredAt,
  String? reason,
}) {
  final built = AuditEntry.create(
    id: AuditEntryId(id),
    actorId: UserId(adminUuid),
    action: action,
    targetRef: targetRef,
    occurredAt: occurredAt,
    reason: reason,
  );
  return (built as Ok<AuditEntry>).value;
}

void main() {
  late InMemoryAuditLogRepository auditLog;
  late ListAuditLog listAuditLog;

  setUp(() {
    auditLog = InMemoryAuditLogRepository();
    listAuditLog = ListAuditLog(auditLog: auditLog);
  });

  final admin = principal(userId: adminUuid);

  group('ListAuditLog', () {
    test('refuses a non-admin caller (authorization) — no read', () async {
      final result = await listAuditLog.call(
        principal: principal(userId: adminUuid, role: PlatformRole.user),
      );
      expect(result, isA<Err<List<AuditEntry>>>());
      final error = (result as Err<List<AuditEntry>>).error;
      expect(error.kind, ErrorKind.authorization);
      expect(error.code, 'auth.insufficient_role');
      // The repository was never consulted.
      expect(auditLog.lastRequestedLimit, isNull);
    });

    test('refuses a plain user even when the trail has rows', () async {
      auditLog.rows.add(
        _seedEntry(
          id: auditUuid,
          action: AuditAction.userSuspended,
          targetRef: targetUuid,
          occurredAt: DateTime.utc(2026, 7, 13, 12),
          reason: 'abuse',
        ),
      );
      final result = await listAuditLog.call(
        principal: principal(userId: adminUuid, role: PlatformRole.user),
      );
      expect(
        (result as Err<List<AuditEntry>>).error.code,
        'auth.insufficient_role',
      );
      expect(auditLog.lastRequestedLimit, isNull);
    });

    test('returns an empty trail as Ok(empty), never an error', () async {
      final result = await listAuditLog.call(principal: admin);
      expect(result.isOk, isTrue);
      expect((result as Ok<List<AuditEntry>>).value, isEmpty);
    });

    test(
      'returns the entries newest-first (occurredAt desc, id desc)',
      () async {
        auditLog.rows.addAll([
          _seedEntry(
            id: auditUuid, // older
            action: AuditAction.userSuspended,
            targetRef: targetUuid,
            occurredAt: DateTime.utc(2026, 7, 13, 10),
            reason: 'first',
          ),
          _seedEntry(
            id: auditUuid2, // newer
            action: AuditAction.userReinstated,
            targetRef: targetUuid,
            occurredAt: DateTime.utc(2026, 7, 13, 14),
            reason: 'second',
          ),
        ]);
        final result = await listAuditLog.call(principal: admin);
        final rows = (result as Ok<List<AuditEntry>>).value;
        expect(rows, hasLength(2));
        // Newest first.
        expect(rows.first.id.value, auditUuid2);
        expect(rows.first.action, AuditAction.userReinstated);
        expect(rows.last.id.value, auditUuid);
      },
    );

    test('a null limit clamps to the default page size', () async {
      final result = await listAuditLog.call(principal: admin);
      expect(result.isOk, isTrue);
      expect(auditLog.lastRequestedLimit, ListAuditLog.defaultLimit);
    });

    test('a non-positive limit clamps to the default page size', () async {
      await listAuditLog.call(principal: admin, limit: 0);
      expect(auditLog.lastRequestedLimit, ListAuditLog.defaultLimit);
      await listAuditLog.call(principal: admin, limit: -5);
      expect(auditLog.lastRequestedLimit, ListAuditLog.defaultLimit);
    });

    test('an over-cap limit clamps to maxLimit', () async {
      await listAuditLog.call(
        principal: admin,
        limit: ListAuditLog.maxLimit + 1,
      );
      expect(auditLog.lastRequestedLimit, ListAuditLog.maxLimit);
    });

    test('an in-range limit is passed through verbatim', () async {
      await listAuditLog.call(principal: admin, limit: 7);
      expect(auditLog.lastRequestedLimit, 7);
    });

    test('propagates a transient read failure', () async {
      auditLog.failNextWith(
        const AppError.transient('db.down', 'temporarily unavailable'),
      );
      final result = await listAuditLog.call(principal: admin);
      expect((result as Err<List<AuditEntry>>).error.kind, ErrorKind.transient);
    });

    test(
      'a service principal (superset of admin) may read the trail',
      () async {
        final result = await listAuditLog.call(
          principal: principal(userId: adminUuid, role: PlatformRole.service),
        );
        expect(result.isOk, isTrue);
      },
    );
  });
}
