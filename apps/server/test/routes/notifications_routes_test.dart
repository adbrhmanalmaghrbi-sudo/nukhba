import 'dart:io';

import 'package:application/application.dart';
import 'package:server/composition/composition_root.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import 'competition_route_harness.dart';
// ignore: always_use_package_imports
import '../../routes/notifications/index.dart' as list_route;
// ignore: always_use_package_imports
import '../../routes/notifications/unread_count/index.dart' as count_route;
// ignore: always_use_package_imports
import '../../routes/notifications/[id]/read/index.dart' as read_route;

/// Route tests for the Notifications (Tier-3) surface — the list route
/// (`GET /notifications`), the unread-count route
/// (`GET /notifications/unread_count`), and the mark-read route
/// (`POST /notifications/{id}/read`), exercised through the *real* wiring
/// (`context.read<Future<CompositionRoot>>()` → `root.<useCase>()`) over the
/// in-memory [InMemoryNotificationRepository] from [competition_route_harness].
/// This covers the edge → use-case → domain → port path end-to-end,
/// hermetically, mirroring `social_routes_test.dart` / `ledger_routes_test.dart`.
///
/// It is NOT a substitute for the infrastructure adapter's own tests
/// (infrastructure package) or the use-cases' own tests (application package):
/// its job is the route's status mapping, DTO shaping, path-param/query
/// handling, and that the recipient-only gate (decision #4 — a caller reads/
/// marks only their OWN notifications; a foreign/unknown id is refused
/// identically as `notification.not_found` with NO existence oracle) is honoured
/// across the HTTP boundary, plus the list's `?limit=` clamp reaching the repo.
void main() {
  // Builds a fresh root wiring the three recipient-facing Notifications
  // use-cases over one shared in-memory repo, so a test can seed a recipient's
  // notifications and observe the route behaviour end-to-end. The clock pins the
  // mark-read timestamp.
  ({CompositionRoot root, InMemoryNotificationRepository notifications})
  rootFor() {
    final notifications = InMemoryNotificationRepository();
    final clock = FixedClock(DateTime.utc(2026, 7, 13, 12));
    final root = CompositionRoot.forTesting(
      listMyNotifications: ListMyNotifications(notifications: notifications),
      getUnreadCount: GetUnreadCount(notifications: notifications),
      markNotificationRead: MarkNotificationRead(
        notifications: notifications,
        clock: clock,
      ),
    );
    return (root: root, notifications: notifications);
  }

  group('GET /notifications (list mine)', () {
    test(
      'a recipient reads their own list (200), newest-first + count',
      () async {
        final setup = rootFor();
        setup.notifications
          ..seed(
            storedNotification(
              id: kNotificationId,
              recipientId: kUserId,
              createdAt: DateTime.utc(2026, 7, 12, 8),
            ),
          )
          ..seed(
            storedNotification(
              id: kNotificationId2,
              recipientId: kUserId,
              createdAt: DateTime.utc(2026, 7, 13, 10),
            ),
          )
          // A notification for someone else must never appear or count.
          ..seed(
            storedNotification(
              id: kNotificationId3,
              recipientId: kMemberUserId,
              createdAt: DateTime.utc(2026, 7, 13, 11),
            ),
          );

        final response = await list_route.onRequest(
          wireContext(
            root: setup.root,
            principal: userPrincipal(),
            method: HttpMethod.get,
          ),
        );

        expect(response.statusCode, HttpStatus.ok);
        final body = await decodeBody(response);
        // The list is scoped to the verified principal (decision #4).
        expect(body['recipient_id'], kUserId);
        final list = body['notifications']! as List<Object?>;
        expect(list.length, 2);
        // Newest-first: the 2026-07-13 notification precedes the 2026-07-12 one.
        expect((list.first! as Map)['id'], kNotificationId2);
        expect((list.last! as Map)['id'], kNotificationId);
        // The count reflects the recipient's WHOLE inbox (both unread), never
        // the foreign row.
        expect(body['unread_count'], 2);
        // A round_scored notification carries its round subject and no points.
        expect((list.first! as Map)['kind'], 'round_scored');
        expect((list.first! as Map)['round_id'], kRoundId);
        expect((list.first! as Map).containsKey('points'), isFalse);
      },
    );

    test(
      'a recipient with no notifications is a legitimate empty list (200)',
      () async {
        final setup = rootFor();

        final response = await list_route.onRequest(
          wireContext(
            root: setup.root,
            principal: userPrincipal(),
            method: HttpMethod.get,
          ),
        );

        expect(response.statusCode, HttpStatus.ok);
        final body = await decodeBody(response);
        expect(body['recipient_id'], kUserId);
        expect(body['notifications'], isEmpty);
        expect(body['unread_count'], 0);
      },
    );

    test('an in-range ?limit= reaches the repository as-is (clamp)', () async {
      final setup = rootFor();

      final response = await list_route.onRequest(
        wireContext(
          root: setup.root,
          principal: userPrincipal(),
          method: HttpMethod.get,
          queryParameters: const {'limit': '10'},
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      expect(setup.notifications.lastLimit, 10);
    });

    test(
      'an over-cap ?limit= is clamped to maxLimit at the repository',
      () async {
        final setup = rootFor();

        final response = await list_route.onRequest(
          wireContext(
            root: setup.root,
            principal: userPrincipal(),
            method: HttpMethod.get,
            queryParameters: const {'limit': '9999'},
          ),
        );

        expect(response.statusCode, HttpStatus.ok);
        expect(setup.notifications.lastLimit, ListMyNotifications.maxLimit);
      },
    );

    test(
      'a non-integer ?limit= falls back to the default at the repository',
      () async {
        final setup = rootFor();

        final response = await list_route.onRequest(
          wireContext(
            root: setup.root,
            principal: userPrincipal(),
            method: HttpMethod.get,
            queryParameters: const {'limit': 'abc'},
          ),
        );

        expect(response.statusCode, HttpStatus.ok);
        expect(setup.notifications.lastLimit, ListMyNotifications.defaultLimit);
      },
    );

    test(
      'a missing ?limit= falls back to the default at the repository',
      () async {
        final setup = rootFor();

        final response = await list_route.onRequest(
          wireContext(
            root: setup.root,
            principal: userPrincipal(),
            method: HttpMethod.get,
          ),
        );

        expect(response.statusCode, HttpStatus.ok);
        expect(setup.notifications.lastLimit, ListMyNotifications.defaultLimit);
      },
    );

    test('a transient repository failure is 503 (Tier-3 confined)', () async {
      final setup = rootFor();
      setup.notifications.failNextWith(
        const AppError.transient('notification.row_corrupt', 'boom'),
      );

      final response = await list_route.onRequest(
        wireContext(
          root: setup.root,
          principal: userPrincipal(),
          method: HttpMethod.get,
        ),
      );

      expect(response.statusCode, HttpStatus.serviceUnavailable);
    });

    test('the list route rejects a non-GET method with 405', () async {
      final setup = rootFor();

      final response = await list_route.onRequest(
        wireContext(
          root: setup.root,
          principal: userPrincipal(),
          method: HttpMethod.post,
        ),
      );

      expect(response.statusCode, HttpStatus.methodNotAllowed);
    });
  });

  group('GET /notifications/unread_count', () {
    test('a recipient reads their own unread count (200)', () async {
      final setup = rootFor();
      setup.notifications
        ..seed(storedNotification(id: kNotificationId, recipientId: kUserId))
        ..seed(
          storedNotification(
            id: kNotificationId2,
            recipientId: kUserId,
            readAt: DateTime.utc(2026, 7, 12, 10),
          ),
        )
        // Another recipient's unread row must not be counted.
        ..seed(
          storedNotification(id: kNotificationId3, recipientId: kMemberUserId),
        );

      final response = await count_route.onRequest(
        wireContext(
          root: setup.root,
          principal: userPrincipal(),
          method: HttpMethod.get,
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      final body = await decodeBody(response);
      // One unread of the recipient's own two rows; the foreign row excluded.
      expect(body['unread_count'], 1);
    });

    test('zero is a legitimate count (200)', () async {
      final setup = rootFor();

      final response = await count_route.onRequest(
        wireContext(
          root: setup.root,
          principal: userPrincipal(),
          method: HttpMethod.get,
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      final body = await decodeBody(response);
      expect(body['unread_count'], 0);
    });

    test('a transient failure is 503 (Tier-3 confined)', () async {
      final setup = rootFor();
      setup.notifications.failNextWith(
        const AppError.transient('notification.row_corrupt', 'boom'),
      );

      final response = await count_route.onRequest(
        wireContext(
          root: setup.root,
          principal: userPrincipal(),
          method: HttpMethod.get,
        ),
      );

      expect(response.statusCode, HttpStatus.serviceUnavailable);
    });

    test('the unread-count route rejects a non-GET method with 405', () async {
      final setup = rootFor();

      final response = await count_route.onRequest(
        wireContext(
          root: setup.root,
          principal: userPrincipal(),
          method: HttpMethod.post,
        ),
      );

      expect(response.statusCode, HttpStatus.methodNotAllowed);
    });
  });

  group('POST /notifications/{id}/read (mark)', () {
    test(
      'a recipient marks their own unread notification read (200 read:true)',
      () async {
        final setup = rootFor();
        setup.notifications.seed(
          storedNotification(id: kNotificationId, recipientId: kUserId),
        );

        final response = await read_route.onRequest(
          wireContext(
            root: setup.root,
            principal: userPrincipal(),
            method: HttpMethod.post,
          ),
          kNotificationId,
        );

        expect(response.statusCode, HttpStatus.ok);
        final body = await decodeBody(response);
        // true = transitioned unread→read.
        expect(body['read'], isTrue);
        // The stored row is now read, stamped from the injected clock (UTC).
        expect(setup.notifications.notifications.single.isRead, isTrue);
        expect(
          setup.notifications.notifications.single.readAt,
          DateTime.utc(2026, 7, 13, 12),
        );
      },
    );

    test(
      'marking an already-read notification is idempotent (200 read:false)',
      () async {
        final setup = rootFor();
        final originalReadAt = DateTime.utc(2026, 7, 12, 10);
        setup.notifications.seed(
          storedNotification(
            id: kNotificationId,
            recipientId: kUserId,
            readAt: originalReadAt,
          ),
        );

        final response = await read_route.onRequest(
          wireContext(
            root: setup.root,
            principal: userPrincipal(),
            method: HttpMethod.post,
          ),
          kNotificationId,
        );

        expect(response.statusCode, HttpStatus.ok);
        final body = await decodeBody(response);
        // false = already read (idempotent no-op).
        expect(body['read'], isFalse);
        // The original read timestamp is preserved, never reset.
        expect(setup.notifications.notifications.single.readAt, originalReadAt);
      },
    );

    test("a foreign recipient's notification is refused 401 "
        'notification.not_found (no oracle)', () async {
      final setup = rootFor();
      // The notification belongs to a different recipient.
      setup.notifications.seed(
        storedNotification(id: kNotificationId, recipientId: kMemberUserId),
      );

      final response = await read_route.onRequest(
        wireContext(
          root: setup.root,
          principal: userPrincipal(),
          method: HttpMethod.post,
        ),
        kNotificationId,
      );

      expect(response.statusCode, HttpStatus.unauthorized);
      final body = await decodeBody(response);
      expect(body['code'], 'notification.not_found');
      // The foreign row is untouched.
      expect(setup.notifications.notifications.single.isRead, isFalse);
    });

    test(
      'an unknown id is refused 401 notification.not_found (same code)',
      () async {
        final setup = rootFor();
        // No notification seeded at all.

        final response = await read_route.onRequest(
          wireContext(
            root: setup.root,
            principal: userPrincipal(),
            method: HttpMethod.post,
          ),
          kNotificationId,
        );

        expect(response.statusCode, HttpStatus.unauthorized);
        final body = await decodeBody(response);
        // Identical refusal to the foreign case — no existence oracle.
        expect(body['code'], 'notification.not_found');
      },
    );

    test('a malformed id is 400 (validation)', () async {
      final setup = rootFor();

      final response = await read_route.onRequest(
        wireContext(
          root: setup.root,
          principal: userPrincipal(),
          method: HttpMethod.post,
        ),
        'not-a-uuid',
      );

      expect(response.statusCode, HttpStatus.badRequest);
    });

    test('a transient failure is 503 (Tier-3 confined)', () async {
      final setup = rootFor();
      setup.notifications
        ..seed(storedNotification(id: kNotificationId, recipientId: kUserId))
        ..failNextWith(
          const AppError.transient('notification.row_corrupt', 'boom'),
        );

      final response = await read_route.onRequest(
        wireContext(
          root: setup.root,
          principal: userPrincipal(),
          method: HttpMethod.post,
        ),
        kNotificationId,
      );

      expect(response.statusCode, HttpStatus.serviceUnavailable);
    });

    test('the mark-read route rejects a non-POST method with 405', () async {
      final setup = rootFor();

      final response = await read_route.onRequest(
        wireContext(
          root: setup.root,
          principal: userPrincipal(),
          method: HttpMethod.get,
        ),
        kNotificationId,
      );

      expect(response.statusCode, HttpStatus.methodNotAllowed);
    });
  });
}
