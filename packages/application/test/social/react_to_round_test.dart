import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import '../group/fakes.dart' as group_fakes;
import 'fakes.dart';

const _member = 'bbbbbbbb-0000-0000-0000-000000000002';
const _outsider = 'cccccccc-0000-0000-0000-000000000003';
const _groupId = '11111111-1111-1111-1111-111111111111';
const _roundId = '44444444-4444-4444-4444-444444444444';
const _reactionId = '55555555-5555-5555-5555-555555555555';

/// A group repo seeded with a single member (the gate collaborator).
group_fakes.InMemoryGroupRepository _groups() =>
    group_fakes.InMemoryGroupRepository()..seedMembership(
      group_fakes.storedMembership(
        id: '22222222-2222-2222-2222-222222222222',
        groupId: _groupId,
        userId: _member,
      ),
    );

ReactToRound _useCase(
  InMemoryReactionRepository reactions,
  group_fakes.InMemoryGroupRepository groups, {
  List<String> ids = const [_reactionId],
  DateTime? now,
}) => ReactToRound(
  reactions: reactions,
  groups: groups,
  idGenerator: FakeIdGenerator(ids),
  clock: FakeClock(now),
);

void main() {
  group('ReactToRound — member-only, idempotent', () {
    test('a member reacts for the first time (200, one row)', () async {
      final reactions = InMemoryReactionRepository();
      final useCase = _useCase(reactions, _groups());

      final result = await useCase.call(
        principal: principalUser(userId: _member),
        groupId: _groupId,
        roundId: _roundId,
        emoji: 'fire',
      );

      final reaction = (result as Ok<Reaction>).value;
      expect(reaction.id.value, _reactionId);
      expect(reaction.userId.value, _member);
      expect(reaction.emoji.kind, ReactionKind.fire);
      expect(reactions.reactionCount(_groupId, _roundId), 1);
    });

    test('reacting again changes the emoji in place (still one row)', () async {
      final reactions = InMemoryReactionRepository()
        ..seed(
          storedReaction(
            id: _reactionId,
            groupId: _groupId,
            roundId: _roundId,
            userId: _member,
            emoji: ReactionKind.like,
          ),
        );
      final useCase = _useCase(reactions, _groups());

      final result = await useCase.call(
        principal: principalUser(userId: _member),
        groupId: _groupId,
        roundId: _roundId,
        emoji: 'clap',
      );

      final reaction = (result as Ok<Reaction>).value;
      // Same identity + key preserved; emoji swapped.
      expect(reaction.id.value, _reactionId);
      expect(reaction.emoji.kind, ReactionKind.clap);
      expect(reactions.reactionCount(_groupId, _roundId), 1);
    });

    test('a lost concurrent-react race converges by re-reading', () async {
      final reactions = InMemoryReactionRepository();
      final useCase = _useCase(reactions, _groups());

      // Simulate the DB rejecting the insert because a concurrent writer won;
      // the winning row is left in place for the re-read.
      reactions.conflictNextUpsertWith(
        storedReaction(
          id: 'ffffffff-ffff-ffff-ffff-ffffffffffff',
          groupId: _groupId,
          roundId: _roundId,
          userId: _member,
          emoji: ReactionKind.sad,
        ),
      );

      final result = await useCase.call(
        principal: principalUser(userId: _member),
        groupId: _groupId,
        roundId: _roundId,
        emoji: 'shock',
      );

      // Result is successful; the caller's intended emoji is re-applied on the
      // winning row.
      final reaction = (result as Ok<Reaction>).value;
      expect(reaction.emoji.kind, ReactionKind.shock);
      expect(reactions.reactionCount(_groupId, _roundId), 1);
    });

    test('a non-member is refused group.not_a_member (no oracle)', () async {
      final reactions = InMemoryReactionRepository();
      final useCase = _useCase(reactions, _groups());

      final result = await useCase.call(
        principal: principalUser(userId: _outsider),
        groupId: _groupId,
        roundId: _roundId,
        emoji: 'like',
      );

      final err = (result as Err<Reaction>).error;
      expect(err.code, 'group.not_a_member');
      expect(err.kind, ErrorKind.authorization);
      expect(reactions.reactionCount(_groupId, _roundId), 0);
    });

    test('an unknown emoji is a validation failure', () async {
      final reactions = InMemoryReactionRepository();
      final useCase = _useCase(reactions, _groups());

      final result = await useCase.call(
        principal: principalUser(userId: _member),
        groupId: _groupId,
        roundId: _roundId,
        emoji: 'rocket',
      );

      final err = (result as Err<Reaction>).error;
      expect(err.code, 'social.reaction_emoji_unknown');
      expect(err.kind, ErrorKind.validation);
    });

    test('a malformed group id is a validation failure', () async {
      final reactions = InMemoryReactionRepository();
      final useCase = _useCase(reactions, _groups());

      final result = await useCase.call(
        principal: principalUser(userId: _member),
        groupId: 'not-a-uuid',
        roundId: _roundId,
        emoji: 'like',
      );

      expect((result as Err<Reaction>).error.kind, ErrorKind.validation);
    });

    test('a transient storage failure propagates', () async {
      final reactions = InMemoryReactionRepository()
        ..failNextWith(const AppError.transient('social.row_corrupt', 'boom'));
      // The gate check reads membership first, so seed the failure AFTER the
      // gate by scripting the reaction repo's findReaction to fail.
      final useCase = _useCase(reactions, _groups());

      final result = await useCase.call(
        principal: principalUser(userId: _member),
        groupId: _groupId,
        roundId: _roundId,
        emoji: 'like',
      );

      expect((result as Err<Reaction>).error.kind, ErrorKind.transient);
    });
  });
}
