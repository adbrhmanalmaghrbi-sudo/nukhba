import 'package:application/application.dart';
import 'package:contracts/contracts.dart';
import 'package:domain/domain.dart';

/// Projects the Groups (Community) domain/application read values onto their
/// versioned wire shapes (API ADR §4), in one place, so every group
/// read/command response shapes an entity identically.
///
/// A `Group` is an orthogonal social container (Groups decision #1) — these
/// shapes carry NO competition/season/round reference on the group itself. The
/// invite code is a **capability** (decision #3): [groupToDto] is only ever
/// called on a payload the server returns to a **member** of the group (the
/// create-owner, or a member read), never on a non-member-visible surface.
///
/// Integrity boundary (Axioms 2/5): a group leaderboard entry is a
/// **server-produced read value** — its rank/total/entry-count are echoed
/// exactly as the domain ranking + ledger projection produced them; nothing here
/// is client-writable. The per-group [GroupRole] and [EntryKind]-style tokens
/// cross the wire as their stable `wireValue`, never a Dart enum name.

/// Projects a domain [Group] onto the wire [GroupDto].
///
/// [memberCount] is supplied by the caller because it is not carried on the
/// `Group` aggregate itself (a group is orthogonal to its membership rows —
/// decision #1/#2). A freshly-created group has exactly one member (its owner),
/// so its route passes `1`; a member-scoped read passes the roster size it has
/// already loaded.
GroupDto groupToDto(Group group, {required int memberCount}) {
  return GroupDto(
    id: group.id.value,
    name: group.name,
    ownerId: group.ownerId.value,
    inviteCode: group.inviteCode.value,
    // Always UTC (the domain Group.create enforces isUtc); ISO-8601.
    createdAt: group.createdAt.toUtc().toIso8601String(),
    memberCount: memberCount,
  );
}

/// Projects one domain [GroupMembership] onto the wire [GroupMembershipDto].
///
/// The per-group [role] crosses the wire as its stable [GroupRole.wireValue]
/// token (`owner`/`member`), never the Dart enum name. Carries no competition
/// reference (decision #1/#2 — membership is independent of participation).
GroupMembershipDto membershipToDto(GroupMembership membership) {
  return GroupMembershipDto(
    id: membership.id.value,
    groupId: membership.groupId.value,
    userId: membership.userId.value,
    role: membership.role.wireValue,
    // Always UTC (the domain factories enforce isUtc); ISO-8601.
    joinedAt: membership.joinedAt.toUtc().toIso8601String(),
  );
}

/// Shapes the response of `GET /groups/{id}/members` — the group's roster in the
/// server-defined order (joinedAt ascending, the owner first). [groupId] is the
/// requested id every membership shares.
Map<String, Object?> groupMembersJson(
  String groupId,
  List<GroupMembership> members,
) {
  return GroupMembersDto(
    groupId: groupId,
    members: [for (final m in members) membershipToDto(m)],
  ).toJson();
}

/// Projects one ranked [RankedGroupStanding] onto the wire
/// [GroupLeaderboardEntryDto].
///
/// Both the participant id and the member user id travel on the entry (the group
/// roster is user-keyed; the underlying season projection is participant-keyed).
/// The rank/total/entry-count come verbatim from the domain-ranked ledger
/// projection (Axioms 2/5 — no points are client-writable, no rank is invented).
GroupLeaderboardEntryDto rankedStandingToDto(RankedGroupStanding standing) {
  return GroupLeaderboardEntryDto(
    rank: standing.entry.rank,
    participantId: standing.entry.participantId.value,
    userId: standing.userId.value,
    totalPoints: standing.entry.totalPoints,
    entryCount: standing.entry.entryCount,
  );
}

/// Shapes the response of `GET /groups/{id}/seasons/{seasonId}/leaderboard` —
/// the group's ranked standings for a season (the season projection filtered to
/// the group's members — decision #4). An empty [GroupLeaderboard.standings]
/// list is a legitimate empty board, never an error.
Map<String, Object?> groupLeaderboardJson(GroupLeaderboard board) {
  return GroupLeaderboardDto(
    groupId: board.groupId.value,
    seasonId: board.seasonId.value,
    entries: [for (final s in board.standings) rankedStandingToDto(s)],
  ).toJson();
}
