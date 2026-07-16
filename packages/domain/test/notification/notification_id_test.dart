import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

void main() {
  group('NotificationId.tryParse', () {
    test('accepts a canonical UUID', () {
      final result = NotificationId.tryParse(
        'a1b2c3d4-e5f6-7890-abcd-ef1234567890',
      );
      expect(result, isA<Ok<NotificationId>>());
      expect(
        (result as Ok<NotificationId>).value.value,
        'a1b2c3d4-e5f6-7890-abcd-ef1234567890',
      );
    });

    test('rejects a null/empty value as validation', () {
      final r1 = NotificationId.tryParse(null);
      final r2 = NotificationId.tryParse('');
      expect((r1 as Err<NotificationId>).error.kind, ErrorKind.validation);
      expect(r1.error.code, 'notification.notification_id_empty');
      expect(
        (r2 as Err<NotificationId>).error.code,
        'notification.notification_id_empty',
      );
    });

    test('rejects a malformed (non-UUID) value as validation', () {
      final result = NotificationId.tryParse('not-a-uuid');
      expect((result as Err<NotificationId>).error.kind, ErrorKind.validation);
      expect(result.error.code, 'notification.notification_id_malformed');
    });

    test('is a distinct id type from UserId (no accidental mixing)', () {
      const nId = NotificationId('a1b2c3d4-e5f6-7890-abcd-ef1234567890');
      const uId = UserId('a1b2c3d4-e5f6-7890-abcd-ef1234567890');
      expect(nId == uId, isFalse);
    });
  });
}
