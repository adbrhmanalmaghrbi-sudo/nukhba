import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

void main() {
  const id = AuditEntryId('a1b2c3d4-e5f6-7890-abcd-ef1234567890');
  const actorId = UserId('b1b2c3d4-e5f6-7890-abcd-ef1234567890');
  final occurredAt = DateTime.utc(2026, 7, 13, 9, 15);

  group('AuditEntry.create', () {
    test('creates a valid entry with a reason', () {
      final result = AuditEntry.create(
        id: id,
        actorId: actorId,
        action: AuditAction.userSuspended,
        targetRef: 'c1b2c3d4-e5f6-7890-abcd-ef1234567890',
        occurredAt: occurredAt,
        reason: 'Repeated abuse reports',
      );
      final entry = (result as Ok<AuditEntry>).value;
      expect(entry.id, id);
      expect(entry.actorId, actorId);
      expect(entry.action, AuditAction.userSuspended);
      expect(entry.targetRef, 'c1b2c3d4-e5f6-7890-abcd-ef1234567890');
      expect(entry.reason, 'Repeated abuse reports');
      expect(entry.occurredAt, occurredAt);
    });

    test('creates a valid entry with no reason (optional action)', () {
      final result = AuditEntry.create(
        id: id,
        actorId: actorId,
        action: AuditAction.roundScored,
        targetRef: 'round:c1b2c3d4-e5f6-7890-abcd-ef1234567890',
        occurredAt: occurredAt,
      );
      expect((result as Ok<AuditEntry>).value.reason, isNull);
    });

    test('trims the target ref and reason', () {
      final result = AuditEntry.create(
        id: id,
        actorId: actorId,
        action: AuditAction.userSuspended,
        targetRef: '  target-x  ',
        occurredAt: occurredAt,
        reason: '  spammed  ',
      );
      final entry = (result as Ok<AuditEntry>).value;
      expect(entry.targetRef, 'target-x');
      expect(entry.reason, 'spammed');
    });

    test('rejects a non-UTC occurredAt as validation', () {
      final result = AuditEntry.create(
        id: id,
        actorId: actorId,
        action: AuditAction.userSuspended,
        targetRef: 'target',
        occurredAt: DateTime(2026, 7, 13, 9, 15), // local
        reason: 'x',
      );
      final error = (result as Err<AuditEntry>).error;
      expect(error.kind, ErrorKind.validation);
      expect(error.code, 'admin.audit_occurred_at_not_utc');
    });

    test('rejects a blank target ref as validation', () {
      final result = AuditEntry.create(
        id: id,
        actorId: actorId,
        action: AuditAction.userSuspended,
        targetRef: '   ',
        occurredAt: occurredAt,
        reason: 'x',
      );
      expect(
        (result as Err<AuditEntry>).error.code,
        'admin.audit_target_ref_empty',
      );
    });

    test('rejects a supplied blank reason as validation', () {
      final result = AuditEntry.create(
        id: id,
        actorId: actorId,
        action: AuditAction.userSuspended,
        targetRef: 'target',
        occurredAt: occurredAt,
        reason: '   ',
      );
      expect(
        (result as Err<AuditEntry>).error.code,
        'admin.audit_reason_empty',
      );
    });

    test('rejects an over-long reason as validation', () {
      final result = AuditEntry.create(
        id: id,
        actorId: actorId,
        action: AuditAction.userSuspended,
        targetRef: 'target',
        occurredAt: occurredAt,
        reason: 'x' * (AuditEntry.maxReasonLength + 1),
      );
      expect(
        (result as Err<AuditEntry>).error.code,
        'admin.audit_reason_too_long',
      );
    });
  });

  group('AuditEntry equality', () {
    test('is value-comparable over all fields', () {
      final a =
          (AuditEntry.create(
                    id: id,
                    actorId: actorId,
                    action: AuditAction.userSuspended,
                    targetRef: 'target',
                    occurredAt: occurredAt,
                    reason: 'r',
                  )
                  as Ok<AuditEntry>)
              .value;
      final b =
          (AuditEntry.create(
                    id: id,
                    actorId: actorId,
                    action: AuditAction.userSuspended,
                    targetRef: 'target',
                    occurredAt: occurredAt,
                    reason: 'r',
                  )
                  as Ok<AuditEntry>)
              .value;
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('differs when the action differs', () {
      final a =
          (AuditEntry.create(
                    id: id,
                    actorId: actorId,
                    action: AuditAction.userSuspended,
                    targetRef: 'target',
                    occurredAt: occurredAt,
                  )
                  as Ok<AuditEntry>)
              .value;
      final b =
          (AuditEntry.create(
                    id: id,
                    actorId: actorId,
                    action: AuditAction.userReinstated,
                    targetRef: 'target',
                    occurredAt: occurredAt,
                  )
                  as Ok<AuditEntry>)
              .value;
      expect(a == b, isFalse);
    });
  });

  group('AuditEntry.fromStored', () {
    test('rehydrates without validation (typing only)', () {
      final entry = AuditEntry.fromStored(
        id: id,
        actorId: actorId,
        action: AuditAction.participantLedgerViewed,
        targetRef: 'participant:x',
        reason: null,
        occurredAt: occurredAt,
      );
      expect(entry.action, AuditAction.participantLedgerViewed);
      expect(entry.targetRef, 'participant:x');
    });
  });
}
