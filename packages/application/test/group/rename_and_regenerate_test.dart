import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import 'fakes.dart';

const _owner = 'aaaaaaaa-0000-0000-0000-000000000001';
const _member = 'bbbbbbbb-0000-0000-0000-000000000002';
const _outsider = 'cccccccc-0000-0000-0000-000000000003';
const _groupId = '11111111-1111-1111-1111-111111111111';

InMemoryGroupRepository _repoWithOwnerAndMember() {
  return InMemoryGroupRepository()
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
}

void main() {
  group('RenameGroup — owner-only', () {
    test('the owner renames the group', () async {
      final repo = _repoWithOwnerAndMember();
      final useCase = RenameGroup(repository: repo);
      final result = await useCase.call(
        principal: principalUser(userId: _owner),
        groupId: _groupId,
        name: 'Renamed',
      );
      expect((result as Ok<Group>).value.name, 'Renamed');
      final stored =
          (await repo.findGroup(GroupId(_groupId)) as Ok<Group?>).value!;
      expect(stored.name, 'Renamed');
    });

    test('a plain member is refused group.not_owner', () async {
      final useCase = RenameGroup(repository: _repoWithOwnerAndMember());
      final result = await useCase.call(
        principal: principalUser(userId: _member),
        groupId: _groupId,
        name: 'X',
      );
      final error = (result as Err<Group>).error;
      expect(error.code, 'group.not_owner');
      expect(error.kind, ErrorKind.authorization);
    });

    test(
      'a non-member is refused group.not_a_member (no existence oracle)',
      () async {
        final useCase = RenameGroup(repository: _repoWithOwnerAndMember());
        final result = await useCase.call(
          principal: principalUser(userId: _outsider),
          groupId: _groupId,
          name: 'X',
        );
        expect((result as Err<Group>).error.code, 'group.not_a_member');
      },
    );

    test('an empty new name is a validation error', () async {
      final useCase = RenameGroup(repository: _repoWithOwnerAndMember());
      final result = await useCase.call(
        principal: principalUser(userId: _owner),
        groupId: _groupId,
        name: '   ',
      );
      expect((result as Err<Group>).error.code, 'group.name_empty');
    });

    test('a malformed group id is a validation error', () async {
      final useCase = RenameGroup(repository: _repoWithOwnerAndMember());
      final result = await useCase.call(
        principal: principalUser(userId: _owner),
        groupId: 'not-a-uuid',
        name: 'X',
      );
      expect((result as Err<Group>).error.kind, ErrorKind.validation);
    });
  });

  group('RegenerateInvite — owner-only', () {
    test('the owner rotates the code (old code no longer resolves)', () async {
      final repo = _repoWithOwnerAndMember();
      final useCase = RegenerateInvite(
        repository: repo,
        inviteCodeGenerator: FakeInviteCodeGenerator([otherCode]),
      );
      final result = await useCase.call(
        principal: principalUser(userId: _owner),
        groupId: _groupId,
      );
      expect((result as Ok<Group>).value.inviteCode.value, otherCode);
      // Old code no longer resolves.
      final byOld = await repo.findByInviteCode(
        (InviteCode.tryParse(sampleCode) as Ok<InviteCode>).value,
      );
      expect((byOld as Ok<Group?>).value, isNull);
      // New code resolves to the group.
      final byNew = await repo.findByInviteCode(
        (InviteCode.tryParse(otherCode) as Ok<InviteCode>).value,
      );
      expect((byNew as Ok<Group?>).value!.id.value, _groupId);
    });

    test('a plain member is refused group.not_owner', () async {
      final useCase = RegenerateInvite(
        repository: _repoWithOwnerAndMember(),
        inviteCodeGenerator: FakeInviteCodeGenerator([otherCode]),
      );
      final result = await useCase.call(
        principal: principalUser(userId: _member),
        groupId: _groupId,
      );
      expect((result as Err<Group>).error.code, 'group.not_owner');
    });

    test('a non-member is refused group.not_a_member', () async {
      final useCase = RegenerateInvite(
        repository: _repoWithOwnerAndMember(),
        inviteCodeGenerator: FakeInviteCodeGenerator([otherCode]),
      );
      final result = await useCase.call(
        principal: principalUser(userId: _outsider),
        groupId: _groupId,
      );
      expect((result as Err<Group>).error.code, 'group.not_a_member');
    });
  });
}
