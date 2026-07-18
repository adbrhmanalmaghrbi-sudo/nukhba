import 'package:application/application.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import 'fakes.dart';

const _me = 'aaaaaaaa-0000-0000-0000-000000000001';
const _other = 'bbbbbbbb-0000-0000-0000-000000000002';
const _r1 = '44444444-4444-4444-4444-444444444401';

MarkNotificationRead _useCase(
  InMemoryNotificationRepository repo, {
  DateTime? now,
}) => MarkNotificationRead(notifications: repo, clock: FakeClock(now));

void main() {
  group('MarkNotificationRead (recipient-only, idempotent)', () {
    test('marks the caller\'s own unread notification read', () async {
      final repo = InMemoryNotificationRepository()
        ..seed(storedRoundScored(id: uuidA, recipientId: _me, roundId: _r1));

      final result = await _useCase(repo, now: DateTime.utc(2026, 7, 10))(
        principal: principalUser(userId: _me),
        notificationId: uuidA,
      );

      expect((result as Ok<bool>).value, isTrue);
      expect(repo.rowOf(uuidA)!.readAt, DateTime.utc(2026, 7, 10));
    });

    test(
      're-marking an already-read notification is idempotent Ok(false)',
      () async {
        final repo = InMemoryNotificationRepository()
          ..seed(
            storedRoundScored(
              id: uuidA,
              recipientId: _me,
              roundId: _r1,
              readAt: DateTime.utc(2026, 7, 3),
            ),
          );

        final result = await _useCase(repo, now: DateTime.utc(2026, 7, 10))(
          principal: principalUser(userId: _me),
          notificationId: uuidA,
        );

        expect((result as Ok<bool>).value, isFalse);
        expect(
          repo.rowOf(uuidA)!.readAt,
          DateTime.utc(2026, 7, 3),
          reason: 'original timestamp preserved, never reset',
        );
      },
    );

    test(
      'a foreign notification is refused as not_found (no oracle)',
      () async {
        final repo = InMemoryNotificationRepository()
          ..seed(
            storedRoundScored(id: uuidA, recipientId: _other, roundId: _r1),
          );

        final result = await _useCase(repo)(
          principal: principalUser(userId: _me),
          notificationId: uuidA,
        );

        expect(result, isA<Err<bool>>());
        final err = (result as Err<bool>).error;
        expect(err.code, 'notification.not_found');
        expect(err.kind, ErrorKind.authorization);
      },
    );

    test('an unknown notification is refused identically', () async {
      final repo = InMemoryNotificationRepository();
      final result = await _useCase(repo)(
        principal: principalUser(userId: _me),
        notificationId: uuidA,
      );

      expect((result as Err<bool>).error.code, 'notification.not_found');
    });

    test('a malformed id is a validation error', () async {
      final repo = InMemoryNotificationRepository();
      final result = await _useCase(repo)(
        principal: principalUser(userId: _me),
        notificationId: 'not-a-uuid',
      );

      expect(
        (result as Err<bool>).error.code,
        'notification.notification_id_malformed',
      );
    });

    test('propagates a transient failure', () async {
      final repo = InMemoryNotificationRepository()
        ..seed(storedRoundScored(id: uuidA, recipientId: _me, roundId: _r1))
        ..failNextWith(
          const AppError.transient('notification.row_corrupt', 'boom'),
        );

      final result = await _useCase(repo)(
        principal: principalUser(userId: _me),
        notificationId: uuidA,
      );

      expect((result as Err<bool>).error.kind, ErrorKind.transient);
    });
  });
}
