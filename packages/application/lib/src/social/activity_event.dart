import 'package:domain/domain.dart';

/// The kind of a group activity-feed event (Social decision #1: the feed shows
/// round-scored, member-joined, and rank-shift events — a bounded, closed set,
/// no arbitrary object stream).
///
/// A stable wire token travels to the client ([wireValue]); the label/glyph is
/// a presentation concern. Unknown values are never produced (the reader emits
/// only these), so there is no `tryParse` on the produce-only read path.
enum ActivityEventType {
  /// A round in a competition the group's members play was scored (its results
  /// were posted). Carries the round id.
  roundScored,

  /// A member joined the group. Carries the joining user's id.
  memberJoined,

  /// A member's rank on the group leaderboard shifted. Carries the user id and
  /// the old/new rank.
  rankShift;

  /// The stable wire token for this event type.
  String get wireValue => switch (this) {
    ActivityEventType.roundScored => 'round_scored',
    ActivityEventType.memberJoined => 'member_joined',
    ActivityEventType.rankShift => 'rank_shift',
  };
}

/// A single group activity-feed event — an **application read value**, NOT a
/// stored entity (Social decision #2: the Activity Feed is a pure read
/// projection assembled from existing ratified data — `group.group_memberships`
/// join timestamps, scored `competition.rounds` + `ledger` postings, and
/// `leaderboard.season_standings` rank deltas — never a new writable source).
///
/// It is group-scoped ([groupId]) and ordered by [occurredAt] (UTC). The
/// remaining fields are type-specific and nullable, discriminated by [type]:
/// * `roundScored` — [roundId] set; user/rank fields null.
/// * `memberJoined` — [userId] set; round/rank fields null.
/// * `rankShift` — [userId] + [oldRank] + [newRank] set; [roundId] null.
///
/// Carries NO points-write field (Axiom 5) and NO open-graph edge (ADR-001).
final class ActivityEvent {
  const ActivityEvent._({
    required this.type,
    required this.groupId,
    required this.occurredAt,
    this.roundId,
    this.userId,
    this.oldRank,
    this.newRank,
  });

  /// A round-scored event.
  static ActivityEvent roundScored({
    required GroupId groupId,
    required RoundId roundId,
    required DateTime occurredAt,
  }) => ActivityEvent._(
    type: ActivityEventType.roundScored,
    groupId: groupId,
    roundId: roundId,
    occurredAt: occurredAt,
  );

  /// A member-joined event.
  static ActivityEvent memberJoined({
    required GroupId groupId,
    required UserId userId,
    required DateTime occurredAt,
  }) => ActivityEvent._(
    type: ActivityEventType.memberJoined,
    groupId: groupId,
    userId: userId,
    occurredAt: occurredAt,
  );

  /// A rank-shift event.
  static ActivityEvent rankShift({
    required GroupId groupId,
    required UserId userId,
    required int oldRank,
    required int newRank,
    required DateTime occurredAt,
  }) => ActivityEvent._(
    type: ActivityEventType.rankShift,
    groupId: groupId,
    userId: userId,
    oldRank: oldRank,
    newRank: newRank,
    occurredAt: occurredAt,
  );

  /// The event type discriminator.
  final ActivityEventType type;

  /// The group this event is scoped to.
  final GroupId groupId;

  /// When the event occurred (UTC) — the feed's ordering key.
  final DateTime occurredAt;

  /// The round involved (for `roundScored`); else null.
  final RoundId? roundId;

  /// The user involved (for `memberJoined`/`rankShift`); else null.
  final UserId? userId;

  /// The prior rank (for `rankShift`); else null.
  final int? oldRank;

  /// The new rank (for `rankShift`); else null.
  final int? newRank;

  @override
  bool operator ==(Object other) =>
      other is ActivityEvent &&
      other.type == type &&
      other.groupId == groupId &&
      other.occurredAt == occurredAt &&
      other.roundId == roundId &&
      other.userId == userId &&
      other.oldRank == oldRank &&
      other.newRank == newRank;

  @override
  int get hashCode =>
      Object.hash(type, groupId, occurredAt, roundId, userId, oldRank, newRank);

  @override
  String toString() =>
      'ActivityEvent(${type.wireValue}, group: ${groupId.value}, $occurredAt)';
}
