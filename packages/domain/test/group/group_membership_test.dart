import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

const _mId = 'cccccccc-cccc-cccc-cccc-cccccccccccc';
const _groupId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
const _userId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';

void main() {
  group('GroupMembership.owner', () {
    test('creates an owner-role membership', () {
      final result = GroupMembership.owner(
        id: const GroupMembershipId(_mId),
        groupId: const GroupId(_groupId),
        userId: const UserId(_userId),
        joinedAt: DateTime.utc(2026, 7, 11, 10),
      );
      final m = (result as Ok<GroupMembership>).value;
      expect(m.role, GroupRole.owner);
      expect(m.isOwner, isTrue);
      expect(m.groupId.value, _groupId);
      expect(m.userId.value, _userId);
      expect(m.joinedAt, DateTime.utc(2026, 7, 11, 10));
    });

    test('rejects a non-UTC joinedAt as validation', () {
      final result = GroupMembership.owner(
        id: const GroupMembershipId(_mId),
        groupId: const GroupId(_groupId),
        userId: const UserId(_userId),
        joinedAt: DateTime(2026, 7, 11, 10),
      );
      final err = (result as Err<GroupMembership>).error;
      expect(err.kind, ErrorKind.validation);
      expect(err.code, 'group.membership_joined_at_not_utc');
    });
  });

  group('GroupMembership.join', () {
    test('creates a member-role membership', () {
      final result = GroupMembership.join(
        id: const GroupMembershipId(_mId),
        groupId: const GroupId(_groupId),
        userId: const UserId(_userId),
        joinedAt: DateTime.utc(2026, 7, 11, 10),
      );
      final m = (result as Ok<GroupMembership>).value;
      expect(m.role, GroupRole.member);
      expect(m.isOwner, isFalse);
    });

    test('rejects a non-UTC joinedAt', () {
      final result = GroupMembership.join(
        id: const GroupMembershipId(_mId),
        groupId: const GroupId(_groupId),
        userId: const UserId(_userId),
        joinedAt: DateTime(2026, 7, 11, 10),
      );
      expect(
        (result as Err<GroupMembership>).error.code,
        'group.membership_joined_at_not_utc',
      );
    });
  });

  group('GroupMembership equality', () {
    test('value equality over all fields', () {
      final a = GroupMembership.fromStored(
        id: const GroupMembershipId(_mId),
        groupId: const GroupId(_groupId),
        userId: const UserId(_userId),
        role: GroupRole.member,
        joinedAt: DateTime.utc(2026, 7, 11, 10),
      );
      final b = GroupMembership.fromStored(
        id: const GroupMembershipId(_mId),
        groupId: const GroupId(_groupId),
        userId: const UserId(_userId),
        role: GroupRole.member,
        joinedAt: DateTime.utc(2026, 7, 11, 10),
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });
}
