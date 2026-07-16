import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

void main() {
  const uuid = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890';

  group('AuditEntryId.tryParse', () {
    test('accepts a canonical UUID', () {
      final result = AuditEntryId.tryParse(uuid);
      expect((result as Ok<AuditEntryId>).value.value, uuid);
    });

    test('rejects null as validation (empty)', () {
      final result = AuditEntryId.tryParse(null);
      final error = (result as Err<AuditEntryId>).error;
      expect(error.kind, ErrorKind.validation);
      expect(error.code, 'admin.audit_entry_id_empty');
    });

    test('rejects an empty string as validation (empty)', () {
      final result = AuditEntryId.tryParse('');
      expect(
        (result as Err<AuditEntryId>).error.code,
        'admin.audit_entry_id_empty',
      );
    });

    test('rejects a non-UUID as validation (malformed)', () {
      final result = AuditEntryId.tryParse('not-a-uuid');
      final error = (result as Err<AuditEntryId>).error;
      expect(error.kind, ErrorKind.validation);
      expect(error.code, 'admin.audit_entry_id_malformed');
    });

    test('is a distinct id type from UserId (no accidental mixing)', () {
      const auditId = AuditEntryId(uuid);
      const userId = UserId(uuid);
      // Same underlying string, but distinct runtime types → not equal.
      expect(auditId == userId, isFalse);
    });
  });
}
