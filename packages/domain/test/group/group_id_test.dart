import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

const _uuid = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';

void main() {
  group('GroupId.tryParse', () {
    test('accepts a canonical UUID', () {
      final result = GroupId.tryParse(_uuid);
      expect(result, isA<Ok<GroupId>>());
      expect((result as Ok<GroupId>).value.value, _uuid);
    });

    test('rejects null as validation', () {
      final result = GroupId.tryParse(null);
      final err = (result as Err<GroupId>).error;
      expect(err.kind, ErrorKind.validation);
      expect(err.code, 'group.group_id_empty');
    });

    test('rejects empty as validation', () {
      final result = GroupId.tryParse('');
      expect((result as Err<GroupId>).error.code, 'group.group_id_empty');
    });

    test('rejects a non-UUID as validation', () {
      final result = GroupId.tryParse('not-a-uuid');
      final err = (result as Err<GroupId>).error;
      expect(err.kind, ErrorKind.validation);
      expect(err.code, 'group.group_id_malformed');
    });

    test('distinct id types are never equal even with the same value', () {
      expect(const GroupId(_uuid) == const GroupMembershipId(_uuid), isFalse);
    });

    test('value equality holds for same type + value', () {
      expect(const GroupId(_uuid), const GroupId(_uuid));
    });
  });
}
