import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import '../group/fakes.dart' as group_fakes;
import 'fakes.dart';

const _member = 'bbbbbbbb-0000-0000-0000-000000000002';
const _other = 'dddddddd-0000-0000-0000-000000000004';
const _outsider = 'cccccccc-0000-0000-0000-000000000003';
const _groupId = '11111111-1111-1111-1111-111111111111';
const _roundId = '44444444-4444-4444-4444-444444444444';

group_fakes.InMemoryGroupRepository _groups() =>
    group_fakes.InMemoryGroupRepository()..seedMembership(
      group_fakes.storedMembership(
        id: '22222222-2222-2222-2222-222222222222',
        groupId: _groupId,
        userId: _member,
      ),
    );

void main() {
  group('ListRoundReactions — member-only', () {
    test('a member reads reactions in reactedAt-ascending order', () async {
      final reactions = InMemoryReactionRepository()
        ..seed(
          storedReaction(
            id: '55555555-5555-5555-5555-555555555555',
            groupId: _groupId,
            roundId: _roundId,
            userId: _other,
            emoji: ReactionKind.fire,
            reactedAt: DateTime.utc(2026, 7, 5, 13),
          ),
        )
        ..seed(
          storedReaction(
            id: '66666666-6666-6666-6666-666666666666',
            groupId: _groupId,
            roundId: _roundId,
            userId: _member,
            emoji: ReactionKind.like,
            reactedAt: DateTime.utc(2026, 7, 5, 12),
          ),
        );
      final useCase = ListRoundReactions(
        reactions: reactions,
        groups: _groups(),
      );

      final result = await useCase.call(
        principal: principalUser(userId: _member),
        groupId: _groupId,
        roundId: _roundId,
      );

      final list = (result as Ok<List<Reaction>>).value;
      // earlier reactedAt first
      expect(list.map((r) => r.userId.value).toList(), [_member, _other]);
    });

    test('an empty round returns an empty list (legitimate)', () async {
      final reactions = InMemoryReactionRepository();
      final useCase = ListRoundReactions(
        reactions: reactions,
        groups: _groups(),
      );

      final result = await useCase.call(
        principal: principalUser(userId: _member),
        groupId: _groupId,
        roundId: _roundId,
      );

      expect((result as Ok<List<Reaction>>).value, isEmpty);
    });

    test('a non-member is refused group.not_a_member (no oracle)', () async {
      final reactions = InMemoryReactionRepository();
      final useCase = ListRoundReactions(
        reactions: reactions,
        groups: _groups(),
      );

      final result = await useCase.call(
        principal: principalUser(userId: _outsider),
        groupId: _groupId,
        roundId: _roundId,
      );

      final err = (result as Err<List<Reaction>>).error;
      expect(err.code, 'group.not_a_member');
      expect(err.kind, ErrorKind.authorization);
    });

    test('a malformed group id is a validation failure', () async {
      final reactions = InMemoryReactionRepository();
      final useCase = ListRoundReactions(
        reactions: reactions,
        groups: _groups(),
      );

      final result = await useCase.call(
        principal: principalUser(userId: _member),
        groupId: 'not-a-uuid',
        roundId: _roundId,
      );

      expect((result as Err<List<Reaction>>).error.kind, ErrorKind.validation);
    });

    test('a transient storage failure propagates', () async {
      final reactions = InMemoryReactionRepository()
        ..failNextWith(const AppError.transient('social.row_corrupt', 'boom'));
      final useCase = ListRoundReactions(
        reactions: reactions,
        groups: _groups(),
      );

      final result = await useCase.call(
        principal: principalUser(userId: _member),
        groupId: _groupId,
        roundId: _roundId,
      );

      expect((result as Err<List<Reaction>>).error.kind, ErrorKind.transient);
    });
  });
}
