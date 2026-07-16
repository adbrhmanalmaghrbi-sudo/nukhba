import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import 'fakes.dart';

const _recipient = 'aaaaaaaa-0000-0000-0000-000000000001';
const _actor = 'bbbbbbbb-0000-0000-0000-000000000002';
const _roundId = '44444444-4444-4444-4444-444444444444';
const _groupId = '11111111-1111-1111-1111-111111111111';

CreateNotification _useCase(
  InMemoryNotificationRepository repo, {
  List<String>? ids,
  DateTime? now,
}) => CreateNotification(
  notifications: repo,
  idGenerator: FakeIdGenerator(ids ?? const [uuidA]),
  clock: FakeClock(now),
);

void main() {
  group('CreateNotification (idempotent server-side facade)', () {
    test('creates a new notification and stamps a UTC createdAt', () async {
      final repo = InMemoryNotificationRepository();
      final result = await _useCase(repo, now: DateTime.utc(2026, 7, 10, 9))(
        recipientId: const UserId(_recipient),
        kind: NotificationKind.roundScored,
        subject: NotificationSubject.roundScored(
          roundId: const RoundId(_roundId),
        ),
      );

      expect(result, isA<Ok<bool>>());
      expect((result as Ok<bool>).value, isTrue);
      expect(repo.countFor(_recipient), 1);
      final stored = repo.rowOf(uuidA)!;
      expect(stored.createdAt, DateTime.utc(2026, 7, 10, 9));
      expect(stored.createdAt.isUtc, isTrue);
      expect(stored.isRead, isFalse);
    });

    test('idempotent replay of the same event is a no-op skip', () async {
      final repo = InMemoryNotificationRepository();
      final useCase = _useCase(repo, ids: const [uuidA, uuidB]);

      final first = await useCase(
        recipientId: const UserId(_recipient),
        kind: NotificationKind.roundScored,
        subject: NotificationSubject.roundScored(
          roundId: const RoundId(_roundId),
        ),
      );
      final second = await useCase(
        recipientId: const UserId(_recipient),
        kind: NotificationKind.roundScored,
        subject: NotificationSubject.roundScored(
          roundId: const RoundId(_roundId),
        ),
      );

      expect((first as Ok<bool>).value, isTrue);
      expect((second as Ok<bool>).value, isFalse);
      expect(repo.countFor(_recipient), 1, reason: 'never a second row');
    });

    test('a distinct event for the same recipient creates a new row', () async {
      final repo = InMemoryNotificationRepository();
      final useCase = _useCase(repo, ids: const [uuidA, uuidB]);

      await useCase(
        recipientId: const UserId(_recipient),
        kind: NotificationKind.roundScored,
        subject: NotificationSubject.roundScored(
          roundId: const RoundId(_roundId),
        ),
      );
      final other = await useCase(
        recipientId: const UserId(_recipient),
        kind: NotificationKind.reactionReceived,
        subject: NotificationSubject.reactionReceived(
          groupId: const GroupId(_groupId),
          roundId: const RoundId(_roundId),
          actorUserId: const UserId(_actor),
        ),
      );

      expect((other as Ok<bool>).value, isTrue);
      expect(repo.countFor(_recipient), 2);
    });

    test(
      'subject/kind mismatch is a validation error, never persisted',
      () async {
        final repo = InMemoryNotificationRepository();
        final result = await _useCase(repo)(
          recipientId: const UserId(_recipient),
          kind: NotificationKind.roundScored,
          subject: NotificationSubject.groupMemberJoined(
            groupId: const GroupId(_groupId),
            actorUserId: const UserId(_actor),
          ),
        );

        expect(result, isA<Err<bool>>());
        expect(
          (result as Err<bool>).error.code,
          'notification.subject_kind_mismatch',
        );
        expect(repo.countFor(_recipient), 0);
      },
    );

    test('a malformed generated id is a validation error', () async {
      final repo = InMemoryNotificationRepository();
      final result = await _useCase(repo, ids: const ['not-a-uuid'])(
        recipientId: const UserId(_recipient),
        kind: NotificationKind.roundScored,
        subject: NotificationSubject.roundScored(
          roundId: const RoundId(_roundId),
        ),
      );

      expect(result, isA<Err<bool>>());
      expect(
        (result as Err<bool>).error.code,
        'notification.notification_id_malformed',
      );
      expect(repo.countFor(_recipient), 0);
    });

    test('propagates a transient repository failure', () async {
      final repo = InMemoryNotificationRepository()
        ..failNextWith(
          const AppError.transient('notification.row_corrupt', 'boom'),
        );
      final result = await _useCase(repo)(
        recipientId: const UserId(_recipient),
        kind: NotificationKind.roundScored,
        subject: NotificationSubject.roundScored(
          roundId: const RoundId(_roundId),
        ),
      );

      expect(result, isA<Err<bool>>());
      expect((result as Err<bool>).error.kind, ErrorKind.transient);
    });
  });
}
