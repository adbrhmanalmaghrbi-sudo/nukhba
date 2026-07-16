import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import 'fakes.dart';

const _owner = 'aaaaaaaa-0000-0000-0000-000000000001';
const _groupId = '11111111-1111-1111-1111-111111111111';
const _membershipId = '22222222-2222-2222-2222-222222222222';

({CreateGroup useCase, InMemoryGroupRepository repo}) _harness({
  List<String>? ids,
  List<String>? codes,
}) {
  final repo = InMemoryGroupRepository();
  final useCase = CreateGroup(
    repository: repo,
    idGenerator: FakeIdGenerator(ids ?? [_groupId, _membershipId]),
    inviteCodeGenerator: FakeInviteCodeGenerator(codes ?? [sampleCode]),
    clock: FakeClock(),
  );
  return (useCase: useCase, repo: repo);
}

void main() {
  group('CreateGroup', () {
    test(
      'any signed-in user creates a group + owner membership atomically',
      () async {
        final h = _harness();
        final result = await h.useCase.call(
          principal: principalUser(userId: _owner),
          name: '  Champions League Buddies  ',
        );
        final group = (result as Ok<Group>).value;
        expect(group.id.value, _groupId);
        expect(group.ownerId.value, _owner);
        expect(group.name, 'Champions League Buddies'); // trimmed
        expect(group.inviteCode.value, sampleCode);
        expect(group.createdAt, DateTime.utc(2026, 7, 11, 12));
        // Owner membership written atomically.
        expect(h.repo.membershipCount(_groupId), 1);
        final ms = await h.repo.findMembership(
          GroupId(_groupId),
          UserId(_owner),
        );
        final membership = (ms as Ok<GroupMembership?>).value!;
        expect(membership.isOwner, isTrue);
        expect(membership.id.value, _membershipId);
      },
    );

    test('the owner is taken from the principal, never the body', () async {
      final h = _harness();
      final result = await h.useCase.call(
        principal: principalUser(userId: _owner),
        name: 'Mine',
      );
      expect((result as Ok<Group>).value.ownerId.value, _owner);
    });

    test('an empty name is a validation error', () async {
      final h = _harness();
      final result = await h.useCase.call(
        principal: principalUser(userId: _owner),
        name: '   ',
      );
      final error = (result as Err<Group>).error;
      expect(error.code, 'group.name_empty');
      expect(error.kind, ErrorKind.validation);
    });

    test('an over-long name is a validation error', () async {
      final h = _harness();
      final result = await h.useCase.call(
        principal: principalUser(userId: _owner),
        name: 'x' * (Group.maxNameLength + 1),
      );
      expect((result as Err<Group>).error.code, 'group.name_too_long');
    });

    test(
      'two creates make two distinct groups (no create idempotency)',
      () async {
        final h = _harness(
          ids: [
            _groupId,
            _membershipId,
            '33333333-3333-3333-3333-333333333333',
            '44444444-4444-4444-4444-444444444444',
          ],
          codes: [sampleCode, otherCode],
        );
        final a = await h.useCase.call(
          principal: principalUser(userId: _owner),
          name: 'A',
        );
        final b = await h.useCase.call(
          principal: principalUser(userId: _owner),
          name: 'B',
        );
        expect(
          (a as Ok<Group>).value.id.value,
          isNot((b as Ok<Group>).value.id.value),
        );
      },
    );

    test('propagates a transient storage failure', () async {
      final h = _harness();
      h.repo.failNextWith(const AppError.transient('db.down', 'x'));
      final result = await h.useCase.call(
        principal: principalUser(userId: _owner),
        name: 'X',
      );
      expect((result as Err<Group>).error.kind, ErrorKind.transient);
    });
  });
}
