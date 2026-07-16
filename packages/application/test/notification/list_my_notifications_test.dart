import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import 'fakes.dart';

const _me = 'aaaaaaaa-0000-0000-0000-000000000001';
const _other = 'bbbbbbbb-0000-0000-0000-000000000002';
const _r1 = '44444444-4444-4444-4444-444444444401';
const _r2 = '44444444-4444-4444-4444-444444444402';

void main() {
  group('ListMyNotifications (recipient-only)', () {
    test(
      'returns only the caller\'s own notifications, newest-first',
      () async {
        final repo = InMemoryNotificationRepository()
          ..seed(
            storedRoundScored(
              id: uuidA,
              recipientId: _me,
              roundId: _r1,
              createdAt: DateTime.utc(2026, 7, 1),
            ),
          )
          ..seed(
            storedRoundScored(
              id: uuidB,
              recipientId: _me,
              roundId: _r2,
              createdAt: DateTime.utc(2026, 7, 5),
            ),
          )
          ..seed(
            storedRoundScored(
              id: uuidC,
              recipientId: _other,
              roundId: _r1,
              createdAt: DateTime.utc(2026, 7, 9),
            ),
          );

        final result = await ListMyNotifications(notifications: repo)(
          principal: principalUser(userId: _me),
        );

        final list = (result as Ok<List<Notification>>).value;
        expect(list.map((n) => n.id.value), [uuidB, uuidA]);
        expect(list.every((n) => n.recipientId.value == _me), isTrue);
      },
    );

    test('empty list is legitimate', () async {
      final repo = InMemoryNotificationRepository();
      final result = await ListMyNotifications(notifications: repo)(
        principal: principalUser(userId: _me),
      );
      expect((result as Ok<List<Notification>>).value, isEmpty);
    });

    test('null limit falls back to defaultLimit', () async {
      final repo = InMemoryNotificationRepository();
      await ListMyNotifications(notifications: repo)(
        principal: principalUser(userId: _me),
      );
      expect(repo.lastRequestedLimit, ListMyNotifications.defaultLimit);
    });

    test('non-positive limit falls back to defaultLimit', () async {
      final repo = InMemoryNotificationRepository();
      await ListMyNotifications(notifications: repo)(
        principal: principalUser(userId: _me),
        limit: 0,
      );
      expect(repo.lastRequestedLimit, ListMyNotifications.defaultLimit);
    });

    test('over-cap limit is clamped to maxLimit', () async {
      final repo = InMemoryNotificationRepository();
      await ListMyNotifications(notifications: repo)(
        principal: principalUser(userId: _me),
        limit: 10000,
      );
      expect(repo.lastRequestedLimit, ListMyNotifications.maxLimit);
    });

    test('in-range limit reaches the repository unchanged', () async {
      final repo = InMemoryNotificationRepository();
      await ListMyNotifications(notifications: repo)(
        principal: principalUser(userId: _me),
        limit: 7,
      );
      expect(repo.lastRequestedLimit, 7);
    });

    test('propagates a transient failure', () async {
      final repo = InMemoryNotificationRepository()
        ..failNextWith(
          const AppError.transient('notification.row_corrupt', 'boom'),
        );
      final result = await ListMyNotifications(notifications: repo)(
        principal: principalUser(userId: _me),
      );
      expect(
        (result as Err<List<Notification>>).error.kind,
        ErrorKind.transient,
      );
    });
  });

  group('GetUnreadCount (recipient-only)', () {
    test('counts only the caller\'s unread notifications', () async {
      final repo = InMemoryNotificationRepository()
        ..seed(storedRoundScored(id: uuidA, recipientId: _me, roundId: _r1))
        ..seed(
          storedRoundScored(
            id: uuidB,
            recipientId: _me,
            roundId: _r2,
            readAt: DateTime.utc(2026, 7, 6),
          ),
        )
        ..seed(storedRoundScored(id: uuidC, recipientId: _other, roundId: _r1));

      final result = await GetUnreadCount(notifications: repo)(
        principal: principalUser(userId: _me),
      );
      expect((result as Ok<int>).value, 1);
    });

    test('zero is legitimate', () async {
      final repo = InMemoryNotificationRepository();
      final result = await GetUnreadCount(notifications: repo)(
        principal: principalUser(userId: _me),
      );
      expect((result as Ok<int>).value, 0);
    });

    test('propagates a transient failure', () async {
      final repo = InMemoryNotificationRepository()
        ..failNextWith(
          const AppError.transient('notification.row_corrupt', 'boom'),
        );
      final result = await GetUnreadCount(notifications: repo)(
        principal: principalUser(userId: _me),
      );
      expect((result as Err<int>).error.kind, ErrorKind.transient);
    });
  });
}
