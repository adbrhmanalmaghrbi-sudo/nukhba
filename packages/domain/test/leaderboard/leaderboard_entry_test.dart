import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

const _participant = '44444444-4444-4444-4444-444444444444';

LeaderboardEntry _ok({
  int totalPoints = 5,
  int entryCount = 1,
  DateTime? joinedAt,
}) {
  final result = LeaderboardEntry.projected(
    participantId: const ParticipantId(_participant),
    totalPoints: totalPoints,
    entryCount: entryCount,
    joinedAt: joinedAt ?? DateTime.utc(2026, 7, 1, 9),
  );
  return (result as Ok<LeaderboardEntry>).value;
}

void main() {
  group('LeaderboardEntry.projected', () {
    test('builds an unranked, non-ranked entry from a projection', () {
      final entry = _ok(totalPoints: 12, entryCount: 3);
      expect(entry.participantId.value, _participant);
      expect(entry.totalPoints, 12);
      expect(entry.entryCount, 3);
      expect(entry.rank, 0);
      expect(entry.isRanked, isFalse);
    });

    test('allows a zero total (enrolled, never credited)', () {
      final entry = _ok(totalPoints: 0, entryCount: 0);
      expect(entry.totalPoints, 0);
      expect(entry.entryCount, 0);
    });

    test(
      'allows a negative total (corrections netted below zero — Axiom 5)',
      () {
        final entry = _ok(totalPoints: -3, entryCount: 2);
        expect(entry.totalPoints, -3);
      },
    );

    test('rejects a negative entry count', () {
      final result = LeaderboardEntry.projected(
        participantId: const ParticipantId(_participant),
        totalPoints: 5,
        entryCount: -1,
        joinedAt: DateTime.utc(2026),
      );
      final error = (result as Err<LeaderboardEntry>).error;
      expect(error.code, 'leaderboard.entry_count_negative');
      expect(error.kind, ErrorKind.invariant);
    });

    test('rejects a non-UTC joinedAt', () {
      final result = LeaderboardEntry.projected(
        participantId: const ParticipantId(_participant),
        totalPoints: 5,
        entryCount: 1,
        joinedAt: DateTime(2026, 7, 1, 9), // local, not UTC
      );
      final error = (result as Err<LeaderboardEntry>).error;
      expect(error.code, 'leaderboard.entry_joined_at_not_utc');
      expect(error.kind, ErrorKind.validation);
    });
  });

  group('LeaderboardEntry.withRank', () {
    test('places the entry at a positive 1-based rank', () {
      final ranked = (_ok().withRank(1) as Ok<LeaderboardEntry>).value;
      expect(ranked.rank, 1);
      expect(ranked.isRanked, isTrue);
      // The rest of the projection is preserved.
      expect(ranked.totalPoints, 5);
      expect(ranked.participantId.value, _participant);
    });

    test('rejects a zero rank', () {
      final result = _ok().withRank(0);
      final error = (result as Err<LeaderboardEntry>).error;
      expect(error.code, 'leaderboard.rank_not_positive');
      expect(error.kind, ErrorKind.invariant);
    });

    test('rejects a negative rank', () {
      final result = _ok().withRank(-2);
      expect(
        (result as Err<LeaderboardEntry>).error.code,
        'leaderboard.rank_not_positive',
      );
    });
  });

  group('value equality', () {
    test('equal by all fields incl. rank', () {
      final a = (_ok().withRank(2) as Ok<LeaderboardEntry>).value;
      final b = (_ok().withRank(2) as Ok<LeaderboardEntry>).value;
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('rank distinguishes two otherwise-identical entries', () {
      final a = (_ok().withRank(2) as Ok<LeaderboardEntry>).value;
      final b = (_ok().withRank(3) as Ok<LeaderboardEntry>).value;
      expect(a == b, isFalse);
    });
  });
}
