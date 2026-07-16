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

ActivityEvent _joined(String userId, DateTime at) => ActivityEvent.memberJoined(
  groupId: GroupId(_groupId),
  userId: UserId(userId),
  occurredAt: at,
);

void main() {
  group('GetGroupActivityFeed — member-only, pure projection', () {
    test('a member reads the feed newest-first', () async {
      final feed = InMemoryActivityFeedReader()
        ..seed(_groupId, [
          _joined(_member, DateTime.utc(2026, 7, 1)),
          ActivityEvent.roundScored(
            groupId: GroupId(_groupId),
            roundId: RoundId(_roundId),
            occurredAt: DateTime.utc(2026, 7, 5),
          ),
          _joined(_other, DateTime.utc(2026, 7, 3)),
        ]);
      final useCase = GetGroupActivityFeed(feed: feed, groups: _groups());

      final result = await useCase.call(
        principal: principalUser(userId: _member),
        groupId: _groupId,
      );

      final events = (result as Ok<List<ActivityEvent>>).value;
      // newest first: 7-5 (round scored), 7-3 (other joined), 7-1 (member).
      expect(events.map((e) => e.occurredAt).toList(), [
        DateTime.utc(2026, 7, 5),
        DateTime.utc(2026, 7, 3),
        DateTime.utc(2026, 7, 1),
      ]);
      expect(events.first.type, ActivityEventType.roundScored);
    });

    test('an empty feed is legitimate (fresh group)', () async {
      final feed = InMemoryActivityFeedReader();
      final useCase = GetGroupActivityFeed(feed: feed, groups: _groups());

      final result = await useCase.call(
        principal: principalUser(userId: _member),
        groupId: _groupId,
      );

      expect((result as Ok<List<ActivityEvent>>).value, isEmpty);
    });

    test('a null limit falls back to the default', () async {
      final feed = InMemoryActivityFeedReader()..seed(_groupId, const []);
      final useCase = GetGroupActivityFeed(feed: feed, groups: _groups());

      await useCase.call(
        principal: principalUser(userId: _member),
        groupId: _groupId,
      );

      expect(feed.lastRequestedLimit, GetGroupActivityFeed.defaultLimit);
    });

    test('a non-positive limit falls back to the default', () async {
      final feed = InMemoryActivityFeedReader()..seed(_groupId, const []);
      final useCase = GetGroupActivityFeed(feed: feed, groups: _groups());

      await useCase.call(
        principal: principalUser(userId: _member),
        groupId: _groupId,
        limit: 0,
      );

      expect(feed.lastRequestedLimit, GetGroupActivityFeed.defaultLimit);
    });

    test('a limit above the cap is clamped to maxLimit', () async {
      final feed = InMemoryActivityFeedReader()..seed(_groupId, const []);
      final useCase = GetGroupActivityFeed(feed: feed, groups: _groups());

      await useCase.call(
        principal: principalUser(userId: _member),
        groupId: _groupId,
        limit: 100000,
      );

      expect(feed.lastRequestedLimit, GetGroupActivityFeed.maxLimit);
    });

    test('a valid in-range limit is passed through', () async {
      final feed = InMemoryActivityFeedReader()..seed(_groupId, const []);
      final useCase = GetGroupActivityFeed(feed: feed, groups: _groups());

      await useCase.call(
        principal: principalUser(userId: _member),
        groupId: _groupId,
        limit: 10,
      );

      expect(feed.lastRequestedLimit, 10);
    });

    test('a non-member is refused group.not_a_member (no oracle)', () async {
      final feed = InMemoryActivityFeedReader();
      final useCase = GetGroupActivityFeed(feed: feed, groups: _groups());

      final result = await useCase.call(
        principal: principalUser(userId: _outsider),
        groupId: _groupId,
      );

      final err = (result as Err<List<ActivityEvent>>).error;
      expect(err.code, 'group.not_a_member');
      expect(err.kind, ErrorKind.authorization);
    });

    test('a malformed group id is a validation failure', () async {
      final feed = InMemoryActivityFeedReader();
      final useCase = GetGroupActivityFeed(feed: feed, groups: _groups());

      final result = await useCase.call(
        principal: principalUser(userId: _member),
        groupId: 'not-a-uuid',
      );

      expect(
        (result as Err<List<ActivityEvent>>).error.kind,
        ErrorKind.validation,
      );
    });

    test('a transient reader failure propagates', () async {
      final feed = InMemoryActivityFeedReader()
        ..failNextWith(
          const AppError.transient('social.feed_unavailable', 'boom'),
        );
      final useCase = GetGroupActivityFeed(feed: feed, groups: _groups());

      final result = await useCase.call(
        principal: principalUser(userId: _member),
        groupId: _groupId,
      );

      expect(
        (result as Err<List<ActivityEvent>>).error.kind,
        ErrorKind.transient,
      );
    });
  });
}
