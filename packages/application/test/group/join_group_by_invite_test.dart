import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import 'fakes.dart';

const _owner = 'aaaaaaaa-0000-0000-0000-000000000001';
const _joiner = 'bbbbbbbb-0000-0000-0000-000000000002';
const _groupId = '11111111-1111-1111-1111-111111111111';
const _ownerMs = '22222222-2222-2222-2222-222222222222';
const _newMs = '33333333-3333-3333-3333-333333333333';

({JoinGroupByInvite useCase, InMemoryGroupRepository repo}) _harness({
  List<String>? ids,
}) {
  final repo = InMemoryGroupRepository()
    ..seedGroup(storedGroup(id: _groupId, ownerId: _owner))
    ..seedMembership(
      storedMembership(
        id: _ownerMs,
        groupId: _groupId,
        userId: _owner,
        role: GroupRole.owner,
      ),
    );
  final useCase = JoinGroupByInvite(
    repository: repo,
    idGenerator: FakeIdGenerator(ids ?? [_newMs]),
    clock: FakeClock(),
  );
  return (useCase: useCase, repo: repo);
}

void main() {
  group('JoinGroupByInvite', () {
    test('a user joins by a valid code as a member', () async {
      final h = _harness();
      final result = await h.useCase.call(
        principal: principalUser(userId: _joiner),
        inviteCode: sampleCode,
      );
      final ms = (result as Ok<GroupMembership>).value;
      expect(ms.userId.value, _joiner);
      expect(ms.role, GroupRole.member);
      expect(ms.groupId.value, _groupId);
      expect(h.repo.membershipCount(_groupId), 2);
    });

    test('the userId comes from the principal, never the body', () async {
      final h = _harness();
      final ms =
          (await h.useCase.call(
                    principal: principalUser(userId: _joiner),
                    inviteCode: sampleCode,
                  )
                  as Ok<GroupMembership>)
              .value;
      expect(ms.userId.value, _joiner);
    });

    test(
      'an unknown/rotated code is refused with no existence oracle',
      () async {
        final h = _harness();
        final result = await h.useCase.call(
          principal: principalUser(userId: _joiner),
          inviteCode: otherCode, // no group has this code
        );
        final error = (result as Err<GroupMembership>).error;
        expect(error.code, 'group.invite_invalid');
        expect(error.kind, ErrorKind.invariant);
      },
    );

    test('a malformed code is a validation error', () async {
      final h = _harness();
      final result = await h.useCase.call(
        principal: principalUser(userId: _joiner),
        inviteCode: 'short',
      );
      expect((result as Err<GroupMembership>).error.kind, ErrorKind.validation);
    });

    test(
      'joining again is idempotent — returns the existing membership',
      () async {
        final h = _harness();
        await h.useCase.call(
          principal: principalUser(userId: _joiner),
          inviteCode: sampleCode,
        );
        final again = await h.useCase.call(
          principal: principalUser(userId: _joiner),
          inviteCode: sampleCode,
        );
        expect(again, isA<Ok<GroupMembership>>());
        // Still exactly one membership for the joiner (plus the owner) → 2 total.
        expect(h.repo.membershipCount(_groupId), 2);
      },
    );

    test(
      'the owner "joining" their own group is a no-op returning owner row',
      () async {
        final h = _harness();
        final result = await h.useCase.call(
          principal: principalUser(userId: _owner),
          inviteCode: sampleCode,
        );
        final ms = (result as Ok<GroupMembership>).value;
        expect(ms.isOwner, isTrue);
        expect(h.repo.membershipCount(_groupId), 1);
      },
    );

    test('propagates a transient lookup failure', () async {
      final h = _harness();
      h.repo.failNextWith(const AppError.transient('db.down', 'x'));
      final result = await h.useCase.call(
        principal: principalUser(userId: _joiner),
        inviteCode: sampleCode,
      );
      expect((result as Err<GroupMembership>).error.kind, ErrorKind.transient);
    });
  });
}
