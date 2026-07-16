import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

const _groupId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
const _ownerId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';

InviteCode _code([String raw = 'ABCDEFGHJK']) =>
    (InviteCode.tryParse(raw) as Ok<InviteCode>).value;

Group _group({String name = 'The Lads', DateTime? createdAt}) {
  final result = Group.create(
    id: const GroupId(_groupId),
    ownerId: const UserId(_ownerId),
    name: name,
    inviteCode: _code(),
    createdAt: createdAt ?? DateTime.utc(2026, 7, 11, 10),
  );
  return (result as Ok<Group>).value;
}

void main() {
  group('Group.create', () {
    test('builds a group from valid inputs (name trimmed)', () {
      final group = _group(name: '  The Lads  ');
      expect(group.id.value, _groupId);
      expect(group.ownerId.value, _ownerId);
      expect(group.name, 'The Lads');
      expect(group.inviteCode.value, 'ABCDEFGHJK');
      expect(group.createdAt, DateTime.utc(2026, 7, 11, 10));
    });

    test('rejects an empty/whitespace name as validation', () {
      final result = Group.create(
        id: const GroupId(_groupId),
        ownerId: const UserId(_ownerId),
        name: '   ',
        inviteCode: _code(),
        createdAt: DateTime.utc(2026, 7, 11, 10),
      );
      final err = (result as Err<Group>).error;
      expect(err.kind, ErrorKind.validation);
      expect(err.code, 'group.name_empty');
    });

    test('rejects an oversized name as validation', () {
      final result = Group.create(
        id: const GroupId(_groupId),
        ownerId: const UserId(_ownerId),
        name: 'x' * (Group.maxNameLength + 1),
        inviteCode: _code(),
        createdAt: DateTime.utc(2026, 7, 11, 10),
      );
      expect((result as Err<Group>).error.code, 'group.name_too_long');
    });

    test('rejects a non-UTC createdAt as validation', () {
      final result = Group.create(
        id: const GroupId(_groupId),
        ownerId: const UserId(_ownerId),
        name: 'The Lads',
        inviteCode: _code(),
        createdAt: DateTime(2026, 7, 11, 10),
      );
      expect((result as Err<Group>).error.code, 'group.created_at_not_utc');
    });
  });

  group('Group.rename', () {
    test(
      'returns a copy with a new trimmed name, everything else preserved',
      () {
        final renamed = _group().rename('  New Name  ');
        final value = (renamed as Ok<Group>).value;
        expect(value.name, 'New Name');
        expect(value.id, const GroupId(_groupId));
        expect(value.ownerId, const UserId(_ownerId));
        expect(value.inviteCode.value, 'ABCDEFGHJK');
        expect(value.createdAt, DateTime.utc(2026, 7, 11, 10));
      },
    );

    test('rejects an empty new name', () {
      expect(
        ((_group().rename('  ')) as Err<Group>).error.code,
        'group.name_empty',
      );
    });

    test('rejects an oversized new name', () {
      expect(
        ((_group().rename('x' * 200)) as Err<Group>).error.code,
        'group.name_too_long',
      );
    });
  });

  group('Group.regenerateInvite', () {
    test('rotates only the invite code', () {
      final rotated = _group().regenerateInvite(_code('MNPQRSTUVW'));
      expect(rotated.inviteCode.value, 'MNPQRSTUVW');
      expect(rotated.name, 'The Lads');
      expect(rotated.id, const GroupId(_groupId));
      expect(rotated.createdAt, DateTime.utc(2026, 7, 11, 10));
    });
  });

  group('Group equality', () {
    test('value equality over all fields', () {
      expect(_group(), _group());
      expect(_group().hashCode, _group().hashCode);
    });

    test('differs when a field differs', () {
      expect(_group(name: 'A') == _group(name: 'B'), isFalse);
    });
  });
}
