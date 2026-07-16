import 'package:domain/domain.dart';
import 'package:test/test.dart';

void main() {
  const roundId = RoundId('c1b2c3d4-e5f6-7890-abcd-ef1234567890');
  const groupId = GroupId('b1b2c3d4-e5f6-7890-abcd-ef1234567890');
  const actor = UserId('d1b2c3d4-e5f6-7890-abcd-ef1234567890');

  group('NotificationSubject factories', () {
    test('roundScored carries only the round and its kind', () {
      final s = NotificationSubject.roundScored(roundId: roundId);
      expect(s.kind, NotificationKind.roundScored);
      expect(s.roundId, roundId);
      expect(s.groupId, isNull);
      expect(s.actorUserId, isNull);
    });

    test('groupMemberJoined carries the group and joining actor', () {
      final s = NotificationSubject.groupMemberJoined(
        groupId: groupId,
        actorUserId: actor,
      );
      expect(s.kind, NotificationKind.groupMemberJoined);
      expect(s.groupId, groupId);
      expect(s.actorUserId, actor);
      expect(s.roundId, isNull);
    });

    test('reactionReceived carries the group, round, and reacting actor', () {
      final s = NotificationSubject.reactionReceived(
        groupId: groupId,
        roundId: roundId,
        actorUserId: actor,
      );
      expect(s.kind, NotificationKind.reactionReceived);
      expect(s.groupId, groupId);
      expect(s.roundId, roundId);
      expect(s.actorUserId, actor);
    });
  });

  group('NotificationSubject.dedupeRef', () {
    test('is deterministic and kind-specific', () {
      final scored = NotificationSubject.roundScored(roundId: roundId);
      final joined = NotificationSubject.groupMemberJoined(
        groupId: groupId,
        actorUserId: actor,
      );
      final reacted = NotificationSubject.reactionReceived(
        groupId: groupId,
        roundId: roundId,
        actorUserId: actor,
      );
      expect(scored.dedupeRef, 'round:${roundId.value}');
      expect(joined.dedupeRef, 'group_join:${groupId.value}:${actor.value}');
      expect(
        reacted.dedupeRef,
        'reaction:${groupId.value}:${roundId.value}:${actor.value}',
      );
    });

    test('a replay of the same event yields the same ref (idempotent key)', () {
      final a = NotificationSubject.roundScored(roundId: roundId);
      final b = NotificationSubject.roundScored(roundId: roundId);
      expect(a.dedupeRef, b.dedupeRef);
      expect(a, b);
    });

    test('distinct events yield distinct refs', () {
      const otherRound = RoundId('e1b2c3d4-e5f6-7890-abcd-ef1234567890');
      final a = NotificationSubject.roundScored(roundId: roundId);
      final b = NotificationSubject.roundScored(roundId: otherRound);
      expect(a.dedupeRef == b.dedupeRef, isFalse);
    });
  });

  group('NotificationSubject equality', () {
    test('is value-based over all fields', () {
      final a = NotificationSubject.reactionReceived(
        groupId: groupId,
        roundId: roundId,
        actorUserId: actor,
      );
      final b = NotificationSubject.reactionReceived(
        groupId: groupId,
        roundId: roundId,
        actorUserId: actor,
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('fromStored rehydrates the same value', () {
      final built = NotificationSubject.groupMemberJoined(
        groupId: groupId,
        actorUserId: actor,
      );
      const rehydrated = NotificationSubject.fromStored(
        kind: NotificationKind.groupMemberJoined,
        groupId: groupId,
        actorUserId: actor,
      );
      expect(rehydrated, built);
    });
  });
}
