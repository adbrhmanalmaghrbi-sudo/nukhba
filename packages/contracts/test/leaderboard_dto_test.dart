import 'package:contracts/contracts.dart';
import 'package:test/test.dart';

const _entry = LeaderboardEntryDto(
  rank: 1,
  participantId: '44444444-4444-4444-4444-444444444444',
  totalPoints: 12,
  entryCount: 3,
);

const _board = SeasonLeaderboardDto(
  seasonId: '11111111-1111-1111-1111-111111111111',
  entries: [
    LeaderboardEntryDto(
      rank: 1,
      participantId: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      totalPoints: 12,
      entryCount: 3,
    ),
    LeaderboardEntryDto(
      rank: 1,
      participantId: 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
      totalPoints: 12,
      entryCount: 2,
    ),
    LeaderboardEntryDto(
      rank: 3,
      participantId: 'cccccccc-cccc-cccc-cccc-cccccccccccc',
      totalPoints: 5,
      entryCount: 1,
    ),
  ],
);

void main() {
  group('LeaderboardEntryDto', () {
    test('round-trips through JSON with snake_case wire keys', () {
      final json = _entry.toJson();
      expect(
        json.keys,
        containsAll(<String>[
          'schema_version',
          'rank',
          'participant_id',
          'total_points',
          'entry_count',
        ]),
      );
      expect(LeaderboardEntryDto.fromJson(json), _entry);
    });

    test('defaults schema_version for a legacy payload lacking the field', () {
      final json = _entry.toJson()..remove('schema_version');
      expect(LeaderboardEntryDto.fromJson(json).schemaVersion, 1);
    });

    test('carries a signed total (a net correction may be negative)', () {
      const negative = LeaderboardEntryDto(
        rank: 4,
        participantId: '44444444-4444-4444-4444-444444444444',
        totalPoints: -3,
        entryCount: 2,
      );
      expect(LeaderboardEntryDto.fromJson(negative.toJson()).totalPoints, -3);
    });

    test('carries no points-write / no group / no prediction leakage', () {
      final keys = _entry.toJson().keys;
      expect(keys, isNot(contains('group_id')));
      expect(keys, isNot(contains('scores')));
      expect(keys, isNot(contains('prediction')));
    });
  });

  group('SeasonLeaderboardDto', () {
    test('round-trips through JSON preserving order', () {
      final json = _board.toJson();
      expect(
        json.keys,
        containsAll(<String>['schema_version', 'season_id', 'entries']),
      );
      final parsed = SeasonLeaderboardDto.fromJson(json);
      expect(parsed, _board);
      expect(
        parsed.entries.map((e) => e.participantId).toList(),
        _board.entries.map((e) => e.participantId).toList(),
      );
    });

    test('order is significant for equality', () {
      final reversed = SeasonLeaderboardDto(
        seasonId: _board.seasonId,
        entries: _board.entries.reversed.toList(),
      );
      expect(reversed == _board, isFalse);
    });

    test('empty board round-trips (a season with no participants)', () {
      const empty = SeasonLeaderboardDto(
        seasonId: '11111111-1111-1111-1111-111111111111',
        entries: [],
      );
      final parsed = SeasonLeaderboardDto.fromJson(empty.toJson());
      expect(parsed.entries, isEmpty);
      expect(parsed, empty);
    });

    test('defaults schema_version for a legacy payload lacking the field', () {
      final json = _board.toJson()..remove('schema_version');
      expect(SeasonLeaderboardDto.fromJson(json).schemaVersion, 1);
    });
  });
}
