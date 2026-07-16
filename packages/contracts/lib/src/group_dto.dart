/// Versioned wire shapes for the Groups (Community) context (API ADR §4: DTOs
/// are decoupled from the schema and carry a schema version so client and
/// archived payloads evolve safely).
///
/// These are pure data shapes shared verbatim by client and server; this file
/// depends on nothing (Application ADR §3). A `Group` is an orthogonal social
/// container (Groups decision #1) — these shapes carry NO competition/season/
/// round reference on the group itself. The [inviteCode] is a capability
/// (decision #3, invite-only): it is only ever placed on a payload the server
/// returns to a **member** of the group, never on a non-member-visible surface.
library;

/// The wire shape of a group (read projection of the domain `Group`).
///
/// Names the group by id, carries its display [name], the [ownerId] (the sole
/// owner), the [createdAt] UTC ISO-8601 instant, and the current [inviteCode]
/// (only surfaced to a member — the use-case/route decide who receives this
/// shape). [memberCount] is a server-produced convenience for rendering.
/// Versioned.
final class GroupDto {
  /// Creates a group DTO.
  const GroupDto({
    required this.id,
    required this.name,
    required this.ownerId,
    required this.inviteCode,
    required this.createdAt,
    required this.memberCount,
    this.schemaVersion = currentSchemaVersion,
  });

  /// Deserializes from a JSON map, defaulting [schemaVersion] for legacy
  /// payloads that predate the field.
  factory GroupDto.fromJson(Map<String, Object?> json) {
    return GroupDto(
      schemaVersion: (json['schema_version'] as int?) ?? 1,
      id: json['id']! as String,
      name: json['name']! as String,
      ownerId: json['owner_id']! as String,
      inviteCode: json['invite_code']! as String,
      createdAt: json['created_at']! as String,
      memberCount: json['member_count']! as int,
    );
  }

  /// The current schema version for this DTO.
  static const int currentSchemaVersion = 1;

  /// The group id (UUID string).
  final String id;

  /// The display name.
  final String name;

  /// The owning user id (UUID string).
  final String ownerId;

  /// The current shareable invite code (a capability — only surfaced to a
  /// member).
  final String inviteCode;

  /// When the group was created (UTC ISO-8601).
  final String createdAt;

  /// How many members the group currently has (server-produced convenience).
  final int memberCount;

  /// The schema version of this payload.
  final int schemaVersion;

  /// Serializes to a JSON-encodable map.
  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'id': id,
    'name': name,
    'owner_id': ownerId,
    'invite_code': inviteCode,
    'created_at': createdAt,
    'member_count': memberCount,
  };

  @override
  bool operator ==(Object other) =>
      other is GroupDto &&
      other.id == id &&
      other.name == name &&
      other.ownerId == ownerId &&
      other.inviteCode == inviteCode &&
      other.createdAt == createdAt &&
      other.memberCount == memberCount &&
      other.schemaVersion == schemaVersion;

  @override
  int get hashCode => Object.hash(
    id,
    name,
    ownerId,
    inviteCode,
    createdAt,
    memberCount,
    schemaVersion,
  );
}

/// The wire shape of one group membership (read projection of the domain
/// `GroupMembership`).
///
/// Names the membership by [id], its [groupId] and member [userId], the
/// per-group [role] wire token (`owner`/`member`), and the [joinedAt] UTC
/// ISO-8601 instant. Carries no competition reference (decision #1/#2 — group
/// membership is independent of competition participation). Versioned.
final class GroupMembershipDto {
  /// Creates a group-membership DTO.
  const GroupMembershipDto({
    required this.id,
    required this.groupId,
    required this.userId,
    required this.role,
    required this.joinedAt,
    this.schemaVersion = currentSchemaVersion,
  });

  /// Deserializes from a JSON map, defaulting [schemaVersion] for legacy
  /// payloads that predate the field.
  factory GroupMembershipDto.fromJson(Map<String, Object?> json) {
    return GroupMembershipDto(
      schemaVersion: (json['schema_version'] as int?) ?? 1,
      id: json['id']! as String,
      groupId: json['group_id']! as String,
      userId: json['user_id']! as String,
      role: json['role']! as String,
      joinedAt: json['joined_at']! as String,
    );
  }

  /// The current schema version for this DTO.
  static const int currentSchemaVersion = 1;

  /// The membership id (UUID string).
  final String id;

  /// The group id (UUID string).
  final String groupId;

  /// The member's user id (UUID string).
  final String userId;

  /// The per-group role token (`owner`/`member`).
  final String role;

  /// When the user joined (UTC ISO-8601).
  final String joinedAt;

  /// The schema version of this payload.
  final int schemaVersion;

  /// Serializes to a JSON-encodable map.
  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'id': id,
    'group_id': groupId,
    'user_id': userId,
    'role': role,
    'joined_at': joinedAt,
  };

  @override
  bool operator ==(Object other) =>
      other is GroupMembershipDto &&
      other.id == id &&
      other.groupId == groupId &&
      other.userId == userId &&
      other.role == role &&
      other.joinedAt == joinedAt &&
      other.schemaVersion == schemaVersion;

  @override
  int get hashCode =>
      Object.hash(id, groupId, userId, role, joinedAt, schemaVersion);
}

/// The wire shape of a group's member list — the response of
/// `GET /groups/{id}/members`.
///
/// Names the group by id and carries the [members] in the server-defined order
/// (joinedAt ascending — the owner, who joined first, appears first). Versioned.
final class GroupMembersDto {
  /// Creates a group-members DTO.
  const GroupMembersDto({
    required this.groupId,
    required this.members,
    this.schemaVersion = currentSchemaVersion,
  });

  /// Deserializes from a JSON map, defaulting [schemaVersion] for legacy
  /// payloads that predate the field.
  factory GroupMembersDto.fromJson(Map<String, Object?> json) {
    final raw = json['members']! as List<Object?>;
    return GroupMembersDto(
      schemaVersion: (json['schema_version'] as int?) ?? 1,
      groupId: json['group_id']! as String,
      members: raw
          .map(
            (e) => GroupMembershipDto.fromJson(
              (e! as Map<Object?, Object?>).cast<String, Object?>(),
            ),
          )
          .toList(growable: false),
    );
  }

  /// The current schema version for this DTO.
  static const int currentSchemaVersion = 1;

  /// The group these members belong to (UUID string).
  final String groupId;

  /// The memberships, in the server-defined order.
  final List<GroupMembershipDto> members;

  /// The schema version of this payload.
  final int schemaVersion;

  /// Serializes to a JSON-encodable map.
  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'group_id': groupId,
    'members': [for (final m in members) m.toJson()],
  };

  @override
  bool operator ==(Object other) =>
      other is GroupMembersDto &&
      other.groupId == groupId &&
      _listEquals(other.members, members) &&
      other.schemaVersion == schemaVersion;

  @override
  int get hashCode =>
      Object.hash(groupId, Object.hashAll(members), schemaVersion);

  static bool _listEquals(
    List<GroupMembershipDto> a,
    List<GroupMembershipDto> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// The wire shape of a group leaderboard — the response of
/// `GET /groups/{id}/seasons/{seasonId}/leaderboard`.
///
/// A group leaderboard reuses the **same** season standings projection filtered
/// to the group's members (Groups decision #4 — no new points source, no new
/// ranking logic). This shape therefore mirrors `SeasonLeaderboardDto`'s entry
/// rows (rank/participant-id/signed total/entry-count — all server-produced,
/// none client-writable, Axioms 2/5) but is scoped to a [groupId] + [seasonId].
/// An empty [entries] list is a legitimate result (a group whose members have
/// not been credited in this season, or a group with no season participants).
/// Versioned.
final class GroupLeaderboardEntryDto {
  /// Creates a group-leaderboard-entry DTO.
  const GroupLeaderboardEntryDto({
    required this.rank,
    required this.participantId,
    required this.userId,
    required this.totalPoints,
    required this.entryCount,
    this.schemaVersion = currentSchemaVersion,
  });

  /// Deserializes from a JSON map, defaulting [schemaVersion] for legacy
  /// payloads that predate the field.
  factory GroupLeaderboardEntryDto.fromJson(Map<String, Object?> json) {
    return GroupLeaderboardEntryDto(
      schemaVersion: (json['schema_version'] as int?) ?? 1,
      rank: json['rank']! as int,
      participantId: json['participant_id']! as String,
      userId: json['user_id']! as String,
      totalPoints: json['total_points']! as int,
      entryCount: json['entry_count']! as int,
    );
  }

  /// The current schema version for this DTO.
  static const int currentSchemaVersion = 1;

  /// The standard-competition rank within the group's filtered board.
  final int rank;

  /// The owning participant id (UUID string).
  final String participantId;

  /// The member's user id (UUID string) — how the group's roster maps to a
  /// season participant (the group filters by user, not participant).
  final String userId;

  /// The signed point total (server projection; equals the participant's ledger
  /// balance for the season — Axiom 5).
  final int totalPoints;

  /// How many immutable ledger movements contributed to [totalPoints].
  final int entryCount;

  /// The schema version of this payload.
  final int schemaVersion;

  /// Serializes to a JSON-encodable map.
  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'rank': rank,
    'participant_id': participantId,
    'user_id': userId,
    'total_points': totalPoints,
    'entry_count': entryCount,
  };

  @override
  bool operator ==(Object other) =>
      other is GroupLeaderboardEntryDto &&
      other.rank == rank &&
      other.participantId == participantId &&
      other.userId == userId &&
      other.totalPoints == totalPoints &&
      other.entryCount == entryCount &&
      other.schemaVersion == schemaVersion;

  @override
  int get hashCode => Object.hash(
    rank,
    participantId,
    userId,
    totalPoints,
    entryCount,
    schemaVersion,
  );
}

/// The wire shape of a group's ranked standings for a season — the response of
/// `GET /groups/{id}/seasons/{seasonId}/leaderboard`.
final class GroupLeaderboardDto {
  /// Creates a group-leaderboard DTO.
  const GroupLeaderboardDto({
    required this.groupId,
    required this.seasonId,
    required this.entries,
    this.schemaVersion = currentSchemaVersion,
  });

  /// Deserializes from a JSON map, defaulting [schemaVersion] for legacy
  /// payloads that predate the field.
  factory GroupLeaderboardDto.fromJson(Map<String, Object?> json) {
    final raw = json['entries']! as List<Object?>;
    return GroupLeaderboardDto(
      schemaVersion: (json['schema_version'] as int?) ?? 1,
      groupId: json['group_id']! as String,
      seasonId: json['season_id']! as String,
      entries: raw
          .map(
            (e) => GroupLeaderboardEntryDto.fromJson(
              (e! as Map<Object?, Object?>).cast<String, Object?>(),
            ),
          )
          .toList(growable: false),
    );
  }

  /// The current schema version for this DTO.
  static const int currentSchemaVersion = 1;

  /// The group these standings are filtered to (UUID string).
  final String groupId;

  /// The season these standings are for (UUID string).
  final String seasonId;

  /// The ranked entries, in the server-defined display order.
  final List<GroupLeaderboardEntryDto> entries;

  /// The schema version of this payload.
  final int schemaVersion;

  /// Serializes to a JSON-encodable map.
  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'group_id': groupId,
    'season_id': seasonId,
    'entries': [for (final e in entries) e.toJson()],
  };

  @override
  bool operator ==(Object other) =>
      other is GroupLeaderboardDto &&
      other.groupId == groupId &&
      other.seasonId == seasonId &&
      _listEquals(other.entries, entries) &&
      other.schemaVersion == schemaVersion;

  @override
  int get hashCode =>
      Object.hash(groupId, seasonId, Object.hashAll(entries), schemaVersion);

  static bool _listEquals(
    List<GroupLeaderboardEntryDto> a,
    List<GroupLeaderboardEntryDto> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
