import 'package:contracts/contracts.dart';
import 'package:test/test.dart';

void main() {
  group('GroupDto', () {
    const dto = GroupDto(
      id: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      name: 'The Lads',
      ownerId: 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
      inviteCode: 'ABCDEFGHJK',
      createdAt: '2026-07-11T10:00:00.000Z',
      memberCount: 3,
    );

    test('round-trips through JSON', () {
      expect(GroupDto.fromJson(dto.toJson()), dto);
    });

    test('uses snake_case keys', () {
      final json = dto.toJson();
      expect(
        json.keys,
        containsAll(<String>[
          'schema_version',
          'id',
          'name',
          'owner_id',
          'invite_code',
          'created_at',
          'member_count',
        ]),
      );
    });

    test('defaults schema_version for a legacy payload', () {
      final legacy = dto.toJson()..remove('schema_version');
      expect(GroupDto.fromJson(legacy).schemaVersion, 1);
    });

    test('carries no competition/season reference', () {
      expect(dto.toJson().keys, isNot(contains('season_id')));
      expect(dto.toJson().keys, isNot(contains('competition_id')));
    });
  });

  group('GroupMembershipDto', () {
    const dto = GroupMembershipDto(
      id: 'cccccccc-cccc-cccc-cccc-cccccccccccc',
      groupId: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      userId: 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
      role: 'owner',
      joinedAt: '2026-07-11T10:00:00.000Z',
    );

    test('round-trips through JSON', () {
      expect(GroupMembershipDto.fromJson(dto.toJson()), dto);
    });

    test('uses snake_case keys and stable role token', () {
      final json = dto.toJson();
      expect(json['role'], 'owner');
      expect(
        json.keys,
        containsAll(<String>['group_id', 'user_id', 'joined_at']),
      );
    });
  });

  group('GroupMembersDto', () {
    const member = GroupMembershipDto(
      id: 'dddddddd-dddd-dddd-dddd-dddddddddddd',
      groupId: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      userId: 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee',
      role: 'member',
      joinedAt: '2026-07-11T11:00:00.000Z',
    );
    const dto = GroupMembersDto(
      groupId: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      members: [member],
    );

    test('round-trips through JSON preserving order', () {
      final round = GroupMembersDto.fromJson(dto.toJson());
      expect(round, dto);
      expect(round.members.single.role, 'member');
    });

    test('empty member list is legitimate', () {
      const empty = GroupMembersDto(groupId: 'g', members: []);
      expect(GroupMembersDto.fromJson(empty.toJson()).members, isEmpty);
    });
  });

  group('GroupLeaderboardDto', () {
    const entry = GroupLeaderboardEntryDto(
      rank: 1,
      participantId: '44444444-4444-4444-4444-444444444444',
      userId: 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
      totalPoints: 12,
      entryCount: 3,
    );
    const dto = GroupLeaderboardDto(
      groupId: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      seasonId: 'ffffffff-ffff-ffff-ffff-ffffffffffff',
      entries: [entry],
    );

    test('round-trips through JSON preserving order', () {
      expect(GroupLeaderboardDto.fromJson(dto.toJson()), dto);
    });

    test('entry carries no rank/points as client-writable command field', () {
      // Purely a read shape; verify no group ref leaks onto the entry and the
      // expected server-produced fields are present.
      final json = entry.toJson();
      expect(
        json.keys,
        containsAll(<String>[
          'rank',
          'participant_id',
          'user_id',
          'total_points',
          'entry_count',
        ]),
      );
      expect(json.keys, isNot(contains('group_id')));
    });

    test('order-significant equality', () {
      const other = GroupLeaderboardEntryDto(
        rank: 2,
        participantId: '55555555-5555-5555-5555-555555555555',
        userId: 'cccccccc-cccc-cccc-cccc-cccccccccccc',
        totalPoints: 5,
        entryCount: 1,
      );
      const a = GroupLeaderboardDto(
        groupId: 'g',
        seasonId: 's',
        entries: [entry, other],
      );
      const b = GroupLeaderboardDto(
        groupId: 'g',
        seasonId: 's',
        entries: [other, entry],
      );
      expect(a == b, isFalse);
    });

    test('empty board is legitimate', () {
      const empty = GroupLeaderboardDto(
        groupId: 'g',
        seasonId: 's',
        entries: [],
      );
      expect(GroupLeaderboardDto.fromJson(empty.toJson()).entries, isEmpty);
    });
  });
}
