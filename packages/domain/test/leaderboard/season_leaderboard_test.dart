import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

const _season = '11111111-1111-1111-1111-111111111111';

// Distinct, canonically-comparable participant ids. The final tie-break sorts
// by id value ascending, so 'aaaa…' < 'bbbb…' < 'cccc…'.
const _pA = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
const _pB = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
const _pC = 'cccccccc-cccc-cccc-cccc-cccccccccccc';
const _pD = 'dddddddd-dddd-dddd-dddd-dddddddddddd';

LeaderboardEntry _entry(
  String participant,
  int totalPoints, {
  DateTime? joinedAt,
  int entryCount = 1,
}) {
  final result = LeaderboardEntry.projected(
    participantId: ParticipantId(participant),
    totalPoints: totalPoints,
    entryCount: entryCount,
    joinedAt: joinedAt ?? DateTime.utc(2026, 7, 1, 9),
  );
  return (result as Ok<LeaderboardEntry>).value;
}

SeasonLeaderboard _rank(List<LeaderboardEntry> projections) {
  final result = SeasonLeaderboard.rank(
    seasonId: const SeasonId(_season),
    projections: projections,
  );
  return (result as Ok<SeasonLeaderboard>).value;
}

void main() {
  group('SeasonLeaderboard.rank — ordering', () {
    test('empty projection yields an empty board (not an error)', () {
      final board = _rank(const []);
      expect(board.size, 0);
      expect(board.entries, isEmpty);
      expect(board.seasonId.value, _season);
    });

    test('orders by total points descending', () {
      final board = _rank([_entry(_pA, 3), _entry(_pB, 10), _entry(_pC, 7)]);
      expect(board.entries.map((e) => e.participantId.value).toList(), [
        _pB,
        _pC,
        _pA,
      ]);
      expect(board.entries.map((e) => e.rank).toList(), [1, 2, 3]);
    });

    test('is deterministic regardless of input order', () {
      final ascending = _rank([
        _entry(_pA, 3),
        _entry(_pB, 7),
        _entry(_pC, 10),
      ]);
      final descending = _rank([
        _entry(_pC, 10),
        _entry(_pB, 7),
        _entry(_pA, 3),
      ]);
      expect(ascending, descending);
    });

    test('a zero-total participant still appears, ranked last', () {
      final board = _rank([_entry(_pA, 0, entryCount: 0), _entry(_pB, 5)]);
      expect(board.entries.first.participantId.value, _pB);
      expect(board.entries.last.participantId.value, _pA);
      expect(board.entries.last.totalPoints, 0);
      expect(board.entries.last.rank, 2);
    });

    test('a negative total (net correction) ranks below zero', () {
      final board = _rank([_entry(_pA, -2), _entry(_pB, 0), _entry(_pC, 4)]);
      expect(board.entries.map((e) => e.participantId.value).toList(), [
        _pC,
        _pB,
        _pA,
      ]);
    });
  });

  group('SeasonLeaderboard.rank — tie-break', () {
    test('equal totals: earlier joinedAt sorts first', () {
      final board = _rank([
        _entry(_pB, 8, joinedAt: DateTime.utc(2026, 7, 5)),
        _entry(_pA, 8, joinedAt: DateTime.utc(2026, 7, 2)),
      ]);
      expect(board.entries.first.participantId.value, _pA); // joined earlier
      expect(board.entries.last.participantId.value, _pB);
    });

    test('equal totals + equal joinedAt: lower participant id sorts first', () {
      final at = DateTime.utc(2026, 7, 2);
      final board = _rank([
        _entry(_pC, 8, joinedAt: at),
        _entry(_pA, 8, joinedAt: at),
        _entry(_pB, 8, joinedAt: at),
      ]);
      expect(board.entries.map((e) => e.participantId.value).toList(), [
        _pA,
        _pB,
        _pC,
      ]);
    });
  });

  group('SeasonLeaderboard.rank — standard competition ("1224") ranks', () {
    test('two tied for 1st are followed by rank 3 (the tie is skipped)', () {
      final at = DateTime.utc(2026, 7, 2);
      final board = _rank([
        _entry(_pA, 10, joinedAt: at),
        _entry(_pB, 10, joinedAt: at.add(const Duration(hours: 1))),
        _entry(_pC, 4),
      ]);
      // pA and pB tie on 10 → both rank 1; pC is the 3rd position → rank 3.
      expect(board.entries.map((e) => e.rank).toList(), [1, 1, 3]);
      // Display order among the tie still honours the tie-break (pA joined
      // earlier than pB).
      expect(board.entries[0].participantId.value, _pA);
      expect(board.entries[1].participantId.value, _pB);
    });

    test('three-way tie then a distinct total: 1,1,1,4', () {
      final board = _rank([
        _entry(_pA, 6, joinedAt: DateTime.utc(2026, 7, 1)),
        _entry(_pB, 6, joinedAt: DateTime.utc(2026, 7, 2)),
        _entry(_pC, 6, joinedAt: DateTime.utc(2026, 7, 3)),
        _entry(_pD, 1),
      ]);
      expect(board.entries.map((e) => e.rank).toList(), [1, 1, 1, 4]);
    });

    test('tie in the middle: 1,2,2,4', () {
      final board = _rank([
        _entry(_pA, 10),
        _entry(_pB, 7, joinedAt: DateTime.utc(2026, 7, 1)),
        _entry(_pC, 7, joinedAt: DateTime.utc(2026, 7, 2)),
        _entry(_pD, 3),
      ]);
      expect(board.entries.map((e) => e.rank).toList(), [1, 2, 2, 4]);
    });

    test('every ranked entry has a positive rank', () {
      final board = _rank([_entry(_pA, 5), _entry(_pB, 5)]);
      expect(board.entries.every((e) => e.isRanked), isTrue);
      expect(board.entries.every((e) => e.rank >= 1), isTrue);
    });
  });

  group('SeasonLeaderboard.rank — integrity', () {
    test('rejects a duplicate participant in the projection', () {
      final result = SeasonLeaderboard.rank(
        seasonId: const SeasonId(_season),
        projections: [_entry(_pA, 5), _entry(_pA, 9)],
      );
      final error = (result as Err<SeasonLeaderboard>).error;
      expect(error.code, 'leaderboard.duplicate_participant');
      expect(error.kind, ErrorKind.invariant);
    });

    test('does not mutate the caller\'s list', () {
      final input = [_entry(_pA, 3), _entry(_pB, 9)];
      final before = List<LeaderboardEntry>.of(input);
      _rank(input);
      expect(input, before); // original order untouched
    });

    test('entries list is unmodifiable', () {
      final board = _rank([_entry(_pA, 5)]);
      expect(() => board.entries.add(_entry(_pB, 1)), throwsUnsupportedError);
    });
  });
}
