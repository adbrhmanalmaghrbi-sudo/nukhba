import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

void main() {
  const id = NotificationId('a1b2c3d4-e5f6-7890-abcd-ef1234567890');
  const recipient = UserId('d1b2c3d4-e5f6-7890-abcd-ef1234567890');
  const roundId = RoundId('c1b2c3d4-e5f6-7890-abcd-ef1234567890');
  final createdAt = DateTime.utc(2026, 7, 12, 10, 30);
  final subject = NotificationSubject.roundScored(roundId: roundId);

  group('Notification.create', () {
    test('creates an unread notification from validated inputs', () {
      final result = Notification.create(
        id: id,
        recipientId: recipient,
        kind: NotificationKind.roundScored,
        subject: subject,
        createdAt: createdAt,
      );
      final n = (result as Ok<Notification>).value;
      expect(n.id, id);
      expect(n.recipientId, recipient);
      expect(n.kind, NotificationKind.roundScored);
      expect(n.subject, subject);
      expect(n.createdAt, createdAt);
      expect(n.readAt, isNull);
      expect(n.isRead, isFalse);
    });

    test('rejects a subject whose kind mismatches the notification kind', () {
      final result = Notification.create(
        id: id,
        recipientId: recipient,
        kind: NotificationKind.groupMemberJoined,
        subject: subject, // roundScored subject
        createdAt: createdAt,
      );
      final err = (result as Err<Notification>).error;
      expect(err.kind, ErrorKind.validation);
      expect(err.code, 'notification.subject_kind_mismatch');
    });

    test('rejects a non-UTC createdAt as validation', () {
      final result = Notification.create(
        id: id,
        recipientId: recipient,
        kind: NotificationKind.roundScored,
        subject: subject,
        createdAt: DateTime(2026, 7, 12, 10, 30), // local
      );
      expect(
        (result as Err<Notification>).error.code,
        'notification.created_at_not_utc',
      );
    });
  });

  group('Notification.markRead', () {
    test('sets readAt when unread', () {
      final n =
          (Notification.create(
                    id: id,
                    recipientId: recipient,
                    kind: NotificationKind.roundScored,
                    subject: subject,
                    createdAt: createdAt,
                  )
                  as Ok<Notification>)
              .value;
      final readAt = DateTime.utc(2026, 7, 12, 11);
      final read = (n.markRead(readAt) as Ok<Notification>).value;
      expect(read.isRead, isTrue);
      expect(read.readAt, readAt);
      // Identity + immutable fields preserved.
      expect(read.id, n.id);
      expect(read.recipientId, n.recipientId);
      expect(read.createdAt, n.createdAt);
    });

    test('is idempotent — re-marking preserves the original timestamp', () {
      final n =
          (Notification.create(
                    id: id,
                    recipientId: recipient,
                    kind: NotificationKind.roundScored,
                    subject: subject,
                    createdAt: createdAt,
                  )
                  as Ok<Notification>)
              .value;
      final firstReadAt = DateTime.utc(2026, 7, 12, 11);
      final read = (n.markRead(firstReadAt) as Ok<Notification>).value;
      final again =
          (read.markRead(DateTime.utc(2026, 7, 12, 12)) as Ok<Notification>)
              .value;
      expect(again.readAt, firstReadAt);
      expect(again, read);
    });

    test('rejects a non-UTC nowUtc when unread', () {
      final n =
          (Notification.create(
                    id: id,
                    recipientId: recipient,
                    kind: NotificationKind.roundScored,
                    subject: subject,
                    createdAt: createdAt,
                  )
                  as Ok<Notification>)
              .value;
      final result = n.markRead(DateTime(2026, 7, 12, 11)); // local
      expect(
        (result as Err<Notification>).error.code,
        'notification.read_at_not_utc',
      );
    });
  });

  group('Notification equality', () {
    test('is value-based over all fields', () {
      final a =
          (Notification.create(
                    id: id,
                    recipientId: recipient,
                    kind: NotificationKind.roundScored,
                    subject: subject,
                    createdAt: createdAt,
                  )
                  as Ok<Notification>)
              .value;
      final b = Notification.fromStored(
        id: id,
        recipientId: recipient,
        kind: NotificationKind.roundScored,
        subject: NotificationSubject.fromStored(
          kind: NotificationKind.roundScored,
          roundId: roundId,
        ),
        createdAt: createdAt,
        readAt: null,
      );
      // Same fields ⇒ equal (create() and fromStored() agree).
      expect(a, b);
      expect(a.hashCode, b.hashCode);

      // A different createdAt ⇒ not equal, proving field sensitivity.
      final c = Notification.fromStored(
        id: id,
        recipientId: recipient,
        kind: NotificationKind.roundScored,
        subject: NotificationSubject.fromStored(
          kind: NotificationKind.roundScored,
          roundId: roundId,
        ),
        createdAt: DateTime.utc(2030),
        readAt: null,
      );
      expect(a == c, isFalse);
    });
  });
}
