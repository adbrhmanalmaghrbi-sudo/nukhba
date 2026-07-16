import 'package:domain/domain.dart';

/// One ranked line on a **group** leaderboard: a season [LeaderboardEntry] (with
/// its standard-competition rank already assigned by the pure domain
/// [SeasonLeaderboard.rank]) paired with the owning member's [UserId].
///
/// The season standings projection is keyed by `ParticipantId`, but a group's
/// roster is a set of `UserId`s (decision #4: the group board is the same
/// projection filtered to the group's members). This pairing re-attaches the
/// `userId` to the ranked entry so the group board can be rendered against the
/// group's user-keyed roster — without introducing any new points source or
/// ranking rule (the [entry] and its rank come verbatim from the ledger
/// projection ranked by the domain).
final class RankedGroupStanding {
  /// Pairs a ranked season [entry] with the member [userId] it belongs to.
  const RankedGroupStanding({required this.userId, required this.entry});

  /// The member's platform user id (how the group roster maps to a participant).
  final UserId userId;

  /// The ranked season projection line for that member's participant.
  final LeaderboardEntry entry;

  @override
  bool operator ==(Object other) =>
      other is RankedGroupStanding &&
      other.userId == userId &&
      other.entry == entry;

  @override
  int get hashCode => Object.hash(userId, entry);

  @override
  String toString() =>
      'RankedGroupStanding(user: ${userId.value}, entry: $entry)';
}

/// A group's ranked standings for a single season — the season leaderboard
/// projection filtered to the group's membership (decision #4), ranked by the
/// pure domain and re-keyed to the group's users.
///
/// This is an **application read value**, not a domain aggregate: the
/// user↔participant re-keying is a Groups-context concern (the domain
/// [SeasonLeaderboard] knows only participants; a group is orthogonal to the
/// competition — decision #1). It holds no points of its own; every entry's
/// total and rank come from the ranked [SeasonLeaderboard] (Axiom 5).
final class GroupLeaderboard {
  /// Creates a group leaderboard for [groupId] within [seasonId] from the
  /// already-ranked [standings] (in the domain's display order).
  const GroupLeaderboard({
    required this.groupId,
    required this.seasonId,
    required this.standings,
  });

  /// The group these standings are filtered to.
  final GroupId groupId;

  /// The season these standings are for.
  final SeasonId seasonId;

  /// The ranked standings, in the domain's display order (points desc, joinedAt
  /// asc, participant-id asc). An empty list is a legitimate empty board.
  final List<RankedGroupStanding> standings;

  /// How many members the board ranks.
  int get size => standings.length;

  @override
  bool operator ==(Object other) =>
      other is GroupLeaderboard &&
      other.groupId == groupId &&
      other.seasonId == seasonId &&
      _listEquals(other.standings, standings);

  @override
  int get hashCode => Object.hash(groupId, seasonId, Object.hashAll(standings));

  @override
  String toString() =>
      'GroupLeaderboard(group: ${groupId.value}, season: ${seasonId.value}, '
      '${standings.length} standings)';

  static bool _listEquals(
    List<RankedGroupStanding> a,
    List<RankedGroupStanding> b,
  ) {
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
