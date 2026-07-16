import 'package:domain/src/competition/participant_id.dart';
import 'package:domain/src/competition/season_id.dart';
import 'package:domain/src/leaderboard/leaderboard_entry.dart';
import 'package:shared/shared.dart';

/// A season's ranked standings — the read-side projection of the append-only
/// ledger for a single [CompetitionSeason] (Axiom 4: predict once, rank
/// everywhere; the season is the first and canonical ranking context — see the
/// Leaderboards architecture decision in project-context §2).
///
/// A [SeasonLeaderboard] is a pure, ordered, immutable list of
/// [LeaderboardEntry]s, one per participant of the season, sorted by the total
/// order defined below and carrying a **standard competition ("1224") rank**.
/// It is a *projection*: it holds no points of its own and is never a source of
/// truth — every [LeaderboardEntry.totalPoints] is a SUM already produced by the
/// ledger (Axiom 5). Building one from raw aggregated projections and ranking
/// them is the whole of the domain's Leaderboards responsibility; where the
/// totals come from (a live ledger view) is Infrastructure's concern.
///
/// **Total order (deterministic, reproducible — never arbitrary DB order):**
/// 1. [LeaderboardEntry.totalPoints] descending (more points ranks higher);
/// 2. tie-break: [LeaderboardEntry.joinedAt] ascending (the earlier joiner ranks
///    first among equal totals);
/// 3. final tie-break: [ParticipantId] value ascending (a stable, total order
///    even if two participants somehow share a joinedAt instant).
///
/// **Rank rule — standard competition ranking ("1224"):** entries with equal
/// [LeaderboardEntry.totalPoints] SHARE a rank; the next distinct total skips by
/// the number of tied competitors (two tied for rank 1 are followed by rank 3).
/// This is the widely-understood sports-standings convention and is what a
/// social-first product (Axiom 1) needs so "you and a friend are joint-2nd"
/// reads correctly. Note the tie-break keys (2) and (3) still impose a total
/// *display order* on tied entries even though they share a rank.
final class SeasonLeaderboard {
  const SeasonLeaderboard._({required this.seasonId, required this.entries});

  /// Builds a ranked leaderboard for [seasonId] from the [projections] (one
  /// unranked [LeaderboardEntry] per season participant — typically the output
  /// of the ledger projection adapter, or `LeaderboardEntry.projected`).
  ///
  /// The result is total and deterministic: the same set of projections always
  /// yields the same ordered, ranked board. Steps:
  /// 1. reject a duplicate [ParticipantId] (a projection must carry each
  ///    participant at most once — a repeated participant would double-count and
  ///    corrupt the standings, an [ErrorKind.invariant] failure — Axiom 5);
  /// 2. sort by the [SeasonLeaderboard] total order (points desc, joinedAt asc,
  ///    id asc) — the input order is irrelevant, so an unordered DB read is
  ///    ranked identically;
  /// 3. assign standard-competition ("1224") ranks: position 1-based, equal
  ///    totals share the rank of the first of their group.
  ///
  /// An empty [projections] yields an empty board (a season with no participants
  /// — a legitimate empty result, not an error).
  static Result<SeasonLeaderboard> rank({
    required SeasonId seasonId,
    required List<LeaderboardEntry> projections,
  }) {
    final seen = <String>{};
    for (final entry in projections) {
      if (!seen.add(entry.participantId.value)) {
        return Result.err(
          AppError.invariant(
            'leaderboard.duplicate_participant',
            'Participant ${entry.participantId.value} appears more than once '
                'in the leaderboard projection',
          ),
        );
      }
    }

    // Copy before sorting — never mutate the caller's list.
    final ordered = List<LeaderboardEntry>.of(projections)..sort(_compare);

    final ranked = <LeaderboardEntry>[];
    for (var i = 0; i < ordered.length; i++) {
      final entry = ordered[i];
      // Standard competition ranking: a participant tied on total with the one
      // before them shares that rank; otherwise their rank is their 1-based
      // position (which naturally produces the "skip" after a tie).
      final int position = i + 1;
      final int assigned;
      if (i > 0 && ordered[i - 1].totalPoints == entry.totalPoints) {
        assigned = ranked[i - 1].rank;
      } else {
        assigned = position;
      }
      final placed = entry.withRank(assigned);
      if (placed is Err<LeaderboardEntry>) {
        return Result.err(placed.error);
      }
      ranked.add((placed as Ok<LeaderboardEntry>).value);
    }

    return Result.ok(
      SeasonLeaderboard._(
        seasonId: seasonId,
        entries: List<LeaderboardEntry>.unmodifiable(ranked),
      ),
    );
  }

  /// The total order over entries: points descending, then joinedAt ascending,
  /// then participant id ascending (a stable, total tie-break).
  static int _compare(LeaderboardEntry a, LeaderboardEntry b) {
    // Points descending.
    final byPoints = b.totalPoints.compareTo(a.totalPoints);
    if (byPoints != 0) {
      return byPoints;
    }
    // joinedAt ascending (earlier joiner first).
    final byJoined = a.joinedAt.compareTo(b.joinedAt);
    if (byJoined != 0) {
      return byJoined;
    }
    // participant id ascending (final stable tie-break).
    return a.participantId.value.compareTo(b.participantId.value);
  }

  /// The season these standings are for.
  final SeasonId seasonId;

  /// The ranked entries in display order (total order above). Always an
  /// unmodifiable list; every entry carries a meaningful ([LeaderboardEntry.rank]
  /// >= 1) rank.
  final List<LeaderboardEntry> entries;

  /// How many participants the board ranks.
  int get size => entries.length;

  @override
  bool operator ==(Object other) =>
      other is SeasonLeaderboard &&
      other.seasonId == seasonId &&
      _listEquals(other.entries, entries);

  @override
  int get hashCode => Object.hash(seasonId, Object.hashAll(entries));

  @override
  String toString() =>
      'SeasonLeaderboard(season: ${seasonId.value}, ${entries.length} entries)';

  static bool _listEquals(List<LeaderboardEntry> a, List<LeaderboardEntry> b) {
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }
}
