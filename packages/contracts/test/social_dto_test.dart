import 'package:contracts/contracts.dart';
import 'package:test/test.dart';

void main() {
  group('ReactionDto', () {
    const dto = ReactionDto(
      id: 'a1b2c3d4-e5f6-7890-abcd-ef1234567890',
      groupId: 'b1b2c3d4-e5f6-7890-abcd-ef1234567890',
      roundId: 'c1b2c3d4-e5f6-7890-abcd-ef1234567890',
      userId: 'd1b2c3d4-e5f6-7890-abcd-ef1234567890',
      emoji: 'fire',
      reactedAt: '2026-07-12T10:30:00.000Z',
    );

    test('round-trips through JSON', () {
      expect(ReactionDto.fromJson(dto.toJson()), dto);
    });

    test('serializes snake_case keys and carries no points field', () {
      final json = dto.toJson();
      expect(
        json.keys,
        containsAll(<String>[
          'schema_version',
          'id',
          'group_id',
          'round_id',
          'user_id',
          'emoji',
          'reacted_at',
        ]),
      );
      expect(json.containsKey('points'), isFalse);
      expect(json.containsKey('total_points'), isFalse);
    });

    test('defaults schema_version for legacy payloads', () {
      final legacy = Map<String, Object?>.from(dto.toJson())
        ..remove('schema_version');
      expect(ReactionDto.fromJson(legacy).schemaVersion, 1);
    });
  });

  group('RoundReactionsDto', () {
    const reaction = ReactionDto(
      id: 'a1b2c3d4-e5f6-7890-abcd-ef1234567890',
      groupId: 'b1b2c3d4-e5f6-7890-abcd-ef1234567890',
      roundId: 'c1b2c3d4-e5f6-7890-abcd-ef1234567890',
      userId: 'd1b2c3d4-e5f6-7890-abcd-ef1234567890',
      emoji: 'clap',
      reactedAt: '2026-07-12T10:30:00.000Z',
    );

    test('round-trips a populated list', () {
      const dto = RoundReactionsDto(
        groupId: 'b1b2c3d4-e5f6-7890-abcd-ef1234567890',
        roundId: 'c1b2c3d4-e5f6-7890-abcd-ef1234567890',
        reactions: [reaction],
      );
      expect(RoundReactionsDto.fromJson(dto.toJson()), dto);
    });

    test(
      'an empty list is legitimate and order-significant equality holds',
      () {
        const empty = RoundReactionsDto(
          groupId: 'b1b2c3d4-e5f6-7890-abcd-ef1234567890',
          roundId: 'c1b2c3d4-e5f6-7890-abcd-ef1234567890',
          reactions: [],
        );
        expect(RoundReactionsDto.fromJson(empty.toJson()), empty);

        const other = ReactionDto(
          id: 'e1b2c3d4-e5f6-7890-abcd-ef1234567890',
          groupId: 'b1b2c3d4-e5f6-7890-abcd-ef1234567890',
          roundId: 'c1b2c3d4-e5f6-7890-abcd-ef1234567890',
          userId: 'f1b2c3d4-e5f6-7890-abcd-ef1234567890',
          emoji: 'sad',
          reactedAt: '2026-07-12T11:00:00.000Z',
        );
        const ab = RoundReactionsDto(
          groupId: 'b1b2c3d4-e5f6-7890-abcd-ef1234567890',
          roundId: 'c1b2c3d4-e5f6-7890-abcd-ef1234567890',
          reactions: [reaction, other],
        );
        const ba = RoundReactionsDto(
          groupId: 'b1b2c3d4-e5f6-7890-abcd-ef1234567890',
          roundId: 'c1b2c3d4-e5f6-7890-abcd-ef1234567890',
          reactions: [other, reaction],
        );
        expect(ab == ba, isFalse);
      },
    );
  });

  group('ActivityEventDto', () {
    test('round_scored omits null type-specific fields', () {
      const dto = ActivityEventDto(
        type: 'round_scored',
        groupId: 'b1b2c3d4-e5f6-7890-abcd-ef1234567890',
        occurredAt: '2026-07-12T10:30:00.000Z',
        roundId: 'c1b2c3d4-e5f6-7890-abcd-ef1234567890',
      );
      final json = dto.toJson();
      expect(json.containsKey('round_id'), isTrue);
      expect(json.containsKey('user_id'), isFalse);
      expect(json.containsKey('old_rank'), isFalse);
      expect(ActivityEventDto.fromJson(json), dto);
    });

    test('rank_shift carries user + old/new rank and round-trips', () {
      const dto = ActivityEventDto(
        type: 'rank_shift',
        groupId: 'b1b2c3d4-e5f6-7890-abcd-ef1234567890',
        occurredAt: '2026-07-12T10:30:00.000Z',
        userId: 'd1b2c3d4-e5f6-7890-abcd-ef1234567890',
        oldRank: 3,
        newRank: 1,
      );
      final json = dto.toJson();
      expect(json['old_rank'], 3);
      expect(json['new_rank'], 1);
      expect(json.containsKey('round_id'), isFalse);
      expect(ActivityEventDto.fromJson(json), dto);
    });

    test('member_joined carries only user and round-trips', () {
      const dto = ActivityEventDto(
        type: 'member_joined',
        groupId: 'b1b2c3d4-e5f6-7890-abcd-ef1234567890',
        occurredAt: '2026-07-12T10:30:00.000Z',
        userId: 'd1b2c3d4-e5f6-7890-abcd-ef1234567890',
      );
      expect(ActivityEventDto.fromJson(dto.toJson()), dto);
    });
  });

  group('GroupActivityFeedDto', () {
    test('round-trips and an empty feed is legitimate', () {
      const empty = GroupActivityFeedDto(
        groupId: 'b1b2c3d4-e5f6-7890-abcd-ef1234567890',
        events: [],
      );
      expect(GroupActivityFeedDto.fromJson(empty.toJson()), empty);

      const feed = GroupActivityFeedDto(
        groupId: 'b1b2c3d4-e5f6-7890-abcd-ef1234567890',
        events: [
          ActivityEventDto(
            type: 'round_scored',
            groupId: 'b1b2c3d4-e5f6-7890-abcd-ef1234567890',
            occurredAt: '2026-07-12T10:30:00.000Z',
            roundId: 'c1b2c3d4-e5f6-7890-abcd-ef1234567890',
          ),
        ],
      );
      expect(GroupActivityFeedDto.fromJson(feed.toJson()), feed);
    });
  });
}
