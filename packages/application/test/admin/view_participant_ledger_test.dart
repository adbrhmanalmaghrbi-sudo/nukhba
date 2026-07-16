import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import 'fakes.dart';

/// Builds a stored [PointEntry] to seed a participant's ledger stream.
PointEntry _entry({
  required String id,
  required String participantId,
  required int amount,
}) {
  final built = PointEntry.create(
    id: PointEntryId(id),
    participantId: ParticipantId(participantId),
    roundId: const RoundId('99999999-9999-4999-8999-999999999999'),
    kind: EntryKind.roundScore,
    amount: amount,
    sourceRef: 'round_score:round:$participantId',
    occurredAt: DateTime.utc(2026, 7, 10, 12),
  );
  return (built as Ok<PointEntry>).value;
}

void main() {
  late InMemoryParticipantReader participants;
  late InMemoryLedgerReadRepository ledger;
  late InMemoryAuditLogRepository auditLog;
  late ViewParticipantLedger view;

  setUp(() {
    participants = InMemoryParticipantReader();
    ledger = InMemoryLedgerReadRepository();
    auditLog = InMemoryAuditLogRepository();
    view = ViewParticipantLedger(
      participantReader: participants,
      ledgerRepository: ledger,
      auditRecorder: auditRecorderOver(auditLog),
    );
  });

  final admin = principal(userId: adminUuid);

  group('ViewParticipantLedger', () {
    test(
      'refuses a non-admin caller (authorization) before any read or audit',
      () async {
        participants.seed(
          storedParticipant(
            id: participantUuid,
            seasonId: seasonUuid,
            userId: targetUuid,
          ),
        );
        final result = await view.call(
          principal: principal(userId: adminUuid, role: PlatformRole.user),
          participantId: participantUuid,
        );
        expect(result, isA<Err<List<PointEntry>>>());
        final error = (result as Err<List<PointEntry>>).error;
        expect(error.kind, ErrorKind.authorization);
        expect(error.code, 'auth.insufficient_role');
        // No cross-user read leaked, and nothing was audited.
        expect(auditLog.rows, isEmpty);
      },
    );

    test('rejects a malformed participant id (validation)', () async {
      final result = await view.call(
        principal: admin,
        participantId: 'not-a-uuid',
      );
      expect(
        (result as Err<List<PointEntry>>).error.kind,
        ErrorKind.validation,
      );
      expect(auditLog.rows, isEmpty);
    });

    test('reports admin.participant_not_found for an absent participant '
        '(no oracle, no audit)', () async {
      final result = await view.call(
        principal: admin,
        participantId: participantUuid,
      );
      final error = (result as Err<List<PointEntry>>).error;
      expect(error.kind, ErrorKind.invariant);
      expect(error.code, 'admin.participant_not_found');
      // A read that never happened leaves no trace.
      expect(auditLog.rows, isEmpty);
    });

    test('serves the participant ledger AND records an audit entry', () async {
      participants.seed(
        storedParticipant(
          id: participantUuid,
          seasonId: seasonUuid,
          userId: targetUuid,
        ),
      );
      ledger.seed(participantUuid, [
        _entry(id: auditUuid, participantId: participantUuid, amount: 10),
        _entry(id: auditUuid2, participantId: participantUuid, amount: 4),
      ]);
      final result = await view.call(
        principal: admin,
        participantId: participantUuid,
        reason: 'support ticket #42',
      );
      expect(result.isOk, isTrue);
      expect((result as Ok<List<PointEntry>>).value, hasLength(2));
      // Audited: exactly one entry, correct action/actor/target/reason.
      expect(auditLog.rows, hasLength(1));
      final entry = auditLog.rows.single;
      expect(entry.action, AuditAction.participantLedgerViewed);
      expect(entry.actorId.value, adminUuid);
      expect(entry.targetRef, participantUuid);
      expect(entry.reason, 'support ticket #42');
    });

    test('serves an empty ledger and still audits the support read', () async {
      participants.seed(
        storedParticipant(
          id: participantUuid,
          seasonId: seasonUuid,
          userId: targetUuid,
        ),
      );
      final result = await view.call(
        principal: admin,
        participantId: participantUuid,
      );
      expect(result.isOk, isTrue);
      expect((result as Ok<List<PointEntry>>).value, isEmpty);
      // The read is audited even when it returns nothing.
      expect(auditLog.rows, hasLength(1));
    });

    test(
      'a null reason is allowed for a support read (not a sanction)',
      () async {
        participants.seed(
          storedParticipant(
            id: participantUuid,
            seasonId: seasonUuid,
            userId: targetUuid,
          ),
        );
        final result = await view.call(
          principal: admin,
          participantId: participantUuid,
        );
        expect(result.isOk, isTrue);
        expect(auditLog.rows.single.reason, isNull);
      },
    );

    test('FAIL-CLOSED: a failed audit write refuses the read rather than '
        'serving un-traced cross-user data', () async {
      participants.seed(
        storedParticipant(
          id: participantUuid,
          seasonId: seasonUuid,
          userId: targetUuid,
        ),
      );
      ledger.seed(participantUuid, [
        _entry(id: auditUuid, participantId: participantUuid, amount: 10),
      ]);
      // The audit append fails.
      auditLog.failNextWith(
        const AppError.transient('db.down', 'temporarily unavailable'),
      );
      final result = await view.call(
        principal: admin,
        participantId: participantUuid,
      );
      // The read is refused (the error propagates), NOT served un-traced.
      expect(result, isA<Err<List<PointEntry>>>());
      expect((result as Err<List<PointEntry>>).error.kind, ErrorKind.transient);
      // Nothing was recorded (the append failed).
      expect(auditLog.rows, isEmpty);
    });

    test(
      'propagates a transient participant-resolution failure (no audit)',
      () async {
        participants.failNextWith(
          const AppError.transient('db.down', 'temporarily unavailable'),
        );
        final result = await view.call(
          principal: admin,
          participantId: participantUuid,
        );
        expect(
          (result as Err<List<PointEntry>>).error.kind,
          ErrorKind.transient,
        );
        expect(auditLog.rows, isEmpty);
      },
    );

    test(
      'a service principal (superset of admin) may perform the support read',
      () async {
        participants.seed(
          storedParticipant(
            id: participantUuid,
            seasonId: seasonUuid,
            userId: targetUuid,
          ),
        );
        final result = await view.call(
          principal: principal(userId: adminUuid, role: PlatformRole.service),
          participantId: participantUuid,
        );
        expect(result.isOk, isTrue);
        expect(auditLog.rows, hasLength(1));
      },
    );
  });
}
