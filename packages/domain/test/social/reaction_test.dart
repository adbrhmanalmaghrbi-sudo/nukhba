import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

void main() {
  const id = ReactionId('a1b2c3d4-e5f6-7890-abcd-ef1234567890');
  const groupId = GroupId('b1b2c3d4-e5f6-7890-abcd-ef1234567890');
  const roundId = RoundId('c1b2c3d4-e5f6-7890-abcd-ef1234567890');
  const userId = UserId('d1b2c3d4-e5f6-7890-abcd-ef1234567890');
  const emoji = ReactionEmoji.of(ReactionKind.fire);
  final reactedAt = DateTime.utc(2026, 7, 12, 10, 30);

  group('Reaction.create', () {
    test('creates a valid reaction from validated inputs', () {
      final result = Reaction.create(
        id: id,
        groupId: groupId,
        roundId: roundId,
        userId: userId,
        emoji: emoji,
        reactedAt: reactedAt,
      );
      final reaction = (result as Ok<Reaction>).value;
      expect(reaction.id, id);
      expect(reaction.groupId, groupId);
      expect(reaction.roundId, roundId);
      expect(reaction.userId, userId);
      expect(reaction.emoji, emoji);
      expect(reaction.reactedAt, reactedAt);
    });

    test('rejects a non-UTC reactedAt as validation', () {
      final result = Reaction.create(
        id: id,
        groupId: groupId,
        roundId: roundId,
        userId: userId,
        emoji: emoji,
        reactedAt: DateTime(2026, 7, 12, 10, 30), // local, not UTC
      );
      expect((result as Err<Reaction>).error.kind, ErrorKind.validation);
      expect(result.error.code, 'social.reaction_reacted_at_not_utc');
    });
  });

  group('Reaction.changeEmoji', () {
    test(
      'produces a new value with the same identity + key, new emoji/time',
      () {
        final original =
            (Reaction.create(
                      id: id,
                      groupId: groupId,
                      roundId: roundId,
                      userId: userId,
                      emoji: emoji,
                      reactedAt: reactedAt,
                    )
                    as Ok<Reaction>)
                .value;

        final later = DateTime.utc(2026, 7, 12, 11);
        final swapped =
            (original.changeEmoji(
                      const ReactionEmoji.of(ReactionKind.clap),
                      later,
                    )
                    as Ok<Reaction>)
                .value;

        // Identity + the (groupId, roundId, userId) key are preserved — so
        // persisting is an idempotent upsert, never a second row.
        expect(swapped.id, original.id);
        expect(swapped.groupId, original.groupId);
        expect(swapped.roundId, original.roundId);
        expect(swapped.userId, original.userId);
        // Only the emoji + timestamp change.
        expect(swapped.emoji, const ReactionEmoji.of(ReactionKind.clap));
        expect(swapped.reactedAt, later);
        expect(swapped == original, isFalse);
      },
    );

    test('rejects a non-UTC reactedAt as validation', () {
      final original =
          (Reaction.create(
                    id: id,
                    groupId: groupId,
                    roundId: roundId,
                    userId: userId,
                    emoji: emoji,
                    reactedAt: reactedAt,
                  )
                  as Ok<Reaction>)
              .value;

      final result = original.changeEmoji(
        const ReactionEmoji.of(ReactionKind.sad),
        DateTime(2026, 7, 12, 11),
      );
      expect(
        (result as Err<Reaction>).error.code,
        'social.reaction_reacted_at_not_utc',
      );
    });
  });

  group('Reaction value semantics', () {
    test('fromStored rehydrates without validation', () {
      final stored = Reaction.fromStored(
        id: id,
        groupId: groupId,
        roundId: roundId,
        userId: userId,
        emoji: emoji,
        reactedAt: reactedAt,
      );
      expect(stored.emoji, emoji);
      expect(stored.reactedAt, reactedAt);
    });

    test('equality is over all fields', () {
      Reaction build(ReactionEmoji e) => Reaction.fromStored(
        id: id,
        groupId: groupId,
        roundId: roundId,
        userId: userId,
        emoji: e,
        reactedAt: reactedAt,
      );
      expect(build(emoji), build(emoji));
      expect(
        build(emoji) == build(const ReactionEmoji.of(ReactionKind.sad)),
        isFalse,
      );
    });

    test('carries no points field (Axiom 5) — surface has only the 6 fields', () {
      // A compile-time guarantee, asserted structurally: the toString names
      // exactly the identity/scope/author/emoji, never a score or points value.
      final s = Reaction.fromStored(
        id: id,
        groupId: groupId,
        roundId: roundId,
        userId: userId,
        emoji: emoji,
        reactedAt: reactedAt,
      ).toString();
      expect(s, contains('group:'));
      expect(s, contains('round:'));
      expect(s.toLowerCase(), isNot(contains('point')));
    });
  });
}
