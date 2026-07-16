import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

void main() {
  group('GroupRole', () {
    test('closed set is exactly {owner, member}', () {
      expect(GroupRole.values, [GroupRole.owner, GroupRole.member]);
    });

    test('wireValue tokens are stable', () {
      expect(GroupRole.owner.wireValue, 'owner');
      expect(GroupRole.member.wireValue, 'member');
    });

    test('isOwner is true only for owner', () {
      expect(GroupRole.owner.isOwner, isTrue);
      expect(GroupRole.member.isOwner, isFalse);
    });

    test('tryParse round-trips every value', () {
      for (final role in GroupRole.values) {
        final parsed = GroupRole.tryParse(role.wireValue);
        expect((parsed as Ok<GroupRole>).value, role);
      }
    });

    test('tryParse rejects unknown/null as validation', () {
      final unknown = GroupRole.tryParse('admin');
      expect((unknown as Err<GroupRole>).error.kind, ErrorKind.validation);
      expect(unknown.error.code, 'group.role_unknown');
      expect(
        (GroupRole.tryParse(null) as Err<GroupRole>).error.code,
        'group.role_unknown',
      );
    });
  });
}
