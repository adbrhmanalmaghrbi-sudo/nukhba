import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import 'fakes.dart';

const _recipient = 'aaaaaaaa-0000-0000-0000-000000000001';
const _owner = 'dddddddd-0000-0000-0000-000000000004';
const _actor = 'bbbbbbbb-0000-0000-0000-000000000002';
const _roundId = '44444444-4444-4444-4444-444444444444';
const _groupId = '11111111-1111-1111-1111-111111111111';

CreateNotification _create(
  InMemoryNotificationRepository repo, {
  List<String>? ids,
}) => CreateNotification(
  notifications: repo,
  idGenerator: FakeIdGenerator(ids ?? const [uuidA, uuidB, uuidC]),
  clock: FakeClock(),
);

void main() {
  group('NotifyRoundScored', () {
    test('creates a round_scored notification for the participant', () async {
      final repo = InMemoryNotificationRepository();
      final result = await NotifyRoundScored(create: _create(repo))(
        recipientId: const UserId(_recipient),
        roundId: const RoundId(_roundId),
      );

      expect((result as Ok<bool>).value, isTrue);
      final stored = repo.rowOf(uuidA)!;
      expect(stored.kind, NotificationKind.roundScored);
      expect(stored.subject.roundId!.value, _roundId);
      expect(stored.recipientId.value, _recipient);
    });

    test('re-scoring the same round never notifies twice (dedupe)', () async {
      final repo = InMemoryNotificationRepository();
      final notify = NotifyRoundScored(create: _create(repo));

      await notify(
        recipientId: const UserId(_recipient),
        roundId: const RoundId(_roundId),
      );
      final replay = await notify(
        recipientId: const UserId(_recipient),
        roundId: const RoundId(_roundId),
      );

      expect((replay as Ok<bool>).value, isFalse);
      expect(repo.countFor(_recipient), 1);
    });
  });

  group('NotifyGroupMemberJoined', () {
    test('notifies the owner with group + joiner subject', () async {
      final repo = InMemoryNotificationRepository();
      final result = await NotifyGroupMemberJoined(create: _create(repo))(
        ownerId: const UserId(_owner),
        groupId: const GroupId(_groupId),
        actorUserId: const UserId(_actor),
      );

      expect((result as Ok<bool>).value, isTrue);
      final stored = repo.rowOf(uuidA)!;
      expect(stored.kind, NotificationKind.groupMemberJoined);
      expect(stored.recipientId.value, _owner);
      expect(stored.subject.groupId!.value, _groupId);
      expect(stored.subject.actorUserId!.value, _actor);
    });

    test('same person joining same group dedupes for the owner', () async {
      final repo = InMemoryNotificationRepository();
      final notify = NotifyGroupMemberJoined(create: _create(repo));

      await notify(
        ownerId: const UserId(_owner),
        groupId: const GroupId(_groupId),
        actorUserId: const UserId(_actor),
      );
      final replay = await notify(
        ownerId: const UserId(_owner),
        groupId: const GroupId(_groupId),
        actorUserId: const UserId(_actor),
      );

      expect((replay as Ok<bool>).value, isFalse);
      expect(repo.countFor(_owner), 1);
    });
  });

  group('NotifyReactionReceived', () {
    test('notifies the round participant with full subject', () async {
      final repo = InMemoryNotificationRepository();
      final result = await NotifyReactionReceived(create: _create(repo))(
        recipientId: const UserId(_recipient),
        groupId: const GroupId(_groupId),
        roundId: const RoundId(_roundId),
        actorUserId: const UserId(_actor),
      );

      expect((result as Ok<bool>).value, isTrue);
      final stored = repo.rowOf(uuidA)!;
      expect(stored.kind, NotificationKind.reactionReceived);
      expect(stored.recipientId.value, _recipient);
      expect(stored.subject.groupId!.value, _groupId);
      expect(stored.subject.roundId!.value, _roundId);
      expect(stored.subject.actorUserId!.value, _actor);
    });

    test('a self-reaction notifies no one (suppressed, Ok(false))', () async {
      final repo = InMemoryNotificationRepository();
      final result = await NotifyReactionReceived(create: _create(repo))(
        recipientId: const UserId(_recipient),
        groupId: const GroupId(_groupId),
        roundId: const RoundId(_roundId),
        actorUserId: const UserId(_recipient),
      );

      expect((result as Ok<bool>).value, isFalse);
      expect(repo.countFor(_recipient), 0, reason: 'no self-notification');
    });

    test('same reactor on same round-result dedupes', () async {
      final repo = InMemoryNotificationRepository();
      final notify = NotifyReactionReceived(create: _create(repo));

      await notify(
        recipientId: const UserId(_recipient),
        groupId: const GroupId(_groupId),
        roundId: const RoundId(_roundId),
        actorUserId: const UserId(_actor),
      );
      final replay = await notify(
        recipientId: const UserId(_recipient),
        groupId: const GroupId(_groupId),
        roundId: const RoundId(_roundId),
        actorUserId: const UserId(_actor),
      );

      expect((replay as Ok<bool>).value, isFalse);
      expect(repo.countFor(_recipient), 1);
    });

    test('Tier-3: a transient failure is a typed err (never throws)', () async {
      final repo = InMemoryNotificationRepository()
        ..failNextWith(
          const AppError.transient('notification.row_corrupt', 'boom'),
        );
      final result = await NotifyReactionReceived(create: _create(repo))(
        recipientId: const UserId(_recipient),
        groupId: const GroupId(_groupId),
        roundId: const RoundId(_roundId),
        actorUserId: const UserId(_actor),
      );

      expect(result, isA<Err<bool>>());
      expect((result as Err<bool>).error.kind, ErrorKind.transient);
    });
  });
}
