import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import 'fakes.dart';

const _owner = 'aaaaaaaa-0000-0000-0000-000000000001';
const _member = 'bbbbbbbb-0000-0000-0000-000000000002';
const _outsider = 'cccccccc-0000-0000-0000-000000000003';
const _groupId = '11111111-1111-1111-1111-111111111111';

InMemoryGroupRepository _repo() => InMemoryGroupRepository()
  ..seedGroup(storedGroup(id: _groupId, ownerId: _owner))
  ..seedMembership(
    storedMembership(
      id: '22222222-2222-2222-2222-222222222222',
      groupId: _groupId,
      userId: _owner,
      role: GroupRole.owner,
      joinedAt: DateTime.utc(2026, 7, 1),
    ),
  )
  ..seedMembership(
    storedMembership(
      id: '33333333-3333-3333-3333-333333333333',
      groupId: _groupId,
      userId: _member,
      joinedAt: DateTime.utc(2026, 7, 2),
    ),
  );

void main() {
  group('ListGroupMembers — member-only', () {
    test('a member reads the roster (owner first, joinedAt asc)', () async {
      final useCase = ListGroupMembers(repository: _repo());
      final result = await useCase.call(
        principal: principalUser(userId: _member),
        groupId: _groupId,
      );
      final members = (result as Ok<List<GroupMembership>>).value;
      expect(members.map((m) => m.userId.value).toList(), [_owner, _member]);
      expect(members.first.isOwner, isTrue);
    });

    test('the owner may also read the roster', () async {
      final useCase = ListGroupMembers(repository: _repo());
      final result = await useCase.call(
        principal: principalUser(userId: _owner),
        groupId: _groupId,
      );
      expect((result as Ok<List<GroupMembership>>).value.length, 2);
    });

    test(
      'a non-member is refused group.not_a_member (no existence oracle)',
      () async {
        final useCase = ListGroupMembers(repository: _repo());
        final result = await useCase.call(
          principal: principalUser(userId: _outsider),
          groupId: _groupId,
        );
        final error = (result as Err<List<GroupMembership>>).error;
        expect(error.code, 'group.not_a_member');
        expect(error.kind, ErrorKind.authorization);
      },
    );

    test('a malformed group id is a validation error', () async {
      final useCase = ListGroupMembers(repository: _repo());
      final result = await useCase.call(
        principal: principalUser(userId: _member),
        groupId: 'not-a-uuid',
      );
      expect(
        (result as Err<List<GroupMembership>>).error.kind,
        ErrorKind.validation,
      );
    });

    test('propagates a transient lookup failure', () async {
      final repo = _repo()..failNextWith(const AppError.transient('db', 'x'));
      final useCase = ListGroupMembers(repository: repo);
      final result = await useCase.call(
        principal: principalUser(userId: _member),
        groupId: _groupId,
      );
      expect(
        (result as Err<List<GroupMembership>>).error.kind,
        ErrorKind.transient,
      );
    });
  });
}
