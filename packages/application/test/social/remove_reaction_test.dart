import 'package:application/application.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import '../group/fakes.dart' as group_fakes;
import 'fakes.dart';

const _member = 'bbbbbbbb-0000-0000-0000-000000000002';
const _outsider = 'cccccccc-0000-0000-0000-000000000003';
const _groupId = '11111111-1111-1111-1111-111111111111';
const _roundId = '44444444-4444-4444-4444-444444444444';
const _reactionId = '55555555-5555-5555-5555-555555555555';

group_fakes.InMemoryGroupRepository _groups() =>
    group_fakes.InMemoryGroupRepository()..seedMembership(
      group_fakes.storedMembership(
        id: '22222222-2222-2222-2222-222222222222',
        groupId: _groupId,
        userId: _member,
      ),
    );

void main() {
  group('RemoveReaction — member-only, idempotent', () {
    test('removes the caller own reaction (Ok(true), zero rows)', () async {
      final reactions = InMemoryReactionRepository()
        ..seed(
          storedReaction(
            id: _reactionId,
            groupId: _groupId,
            roundId: _roundId,
            userId: _member,
          ),
        );
      final useCase = RemoveReaction(reactions: reactions, groups: _groups());

      final result = await useCase.call(
        principal: principalUser(userId: _member),
        groupId: _groupId,
        roundId: _roundId,
      );

      expect((result as Ok<bool>).value, isTrue);
      expect(reactions.reactionCount(_groupId, _roundId), 0);
    });

    test(
      'removing an absent reaction is a no-op success (Ok(false))',
      () async {
        final reactions = InMemoryReactionRepository();
        final useCase = RemoveReaction(reactions: reactions, groups: _groups());

        final result = await useCase.call(
          principal: principalUser(userId: _member),
          groupId: _groupId,
          roundId: _roundId,
        );

        expect((result as Ok<bool>).value, isFalse);
      },
    );

    test('a non-member is refused group.not_a_member (no oracle)', () async {
      final reactions = InMemoryReactionRepository()
        ..seed(
          storedReaction(
            id: _reactionId,
            groupId: _groupId,
            roundId: _roundId,
            userId: _member,
          ),
        );
      final useCase = RemoveReaction(reactions: reactions, groups: _groups());

      final result = await useCase.call(
        principal: principalUser(userId: _outsider),
        groupId: _groupId,
        roundId: _roundId,
      );

      final err = (result as Err<bool>).error;
      expect(err.code, 'group.not_a_member');
      expect(err.kind, ErrorKind.authorization);
      // The member's reaction is untouched.
      expect(reactions.reactionCount(_groupId, _roundId), 1);
    });

    test('a malformed round id is a validation failure', () async {
      final reactions = InMemoryReactionRepository();
      final useCase = RemoveReaction(reactions: reactions, groups: _groups());

      final result = await useCase.call(
        principal: principalUser(userId: _member),
        groupId: _groupId,
        roundId: 'not-a-uuid',
      );

      expect((result as Err<bool>).error.kind, ErrorKind.validation);
    });

    test('a transient storage failure propagates', () async {
      final reactions = InMemoryReactionRepository()
        ..failNextWith(const AppError.transient('social.row_corrupt', 'boom'));
      final useCase = RemoveReaction(reactions: reactions, groups: _groups());

      final result = await useCase.call(
        principal: principalUser(userId: _member),
        groupId: _groupId,
        roundId: _roundId,
      );

      expect((result as Err<bool>).error.kind, ErrorKind.transient);
    });
  });
}
