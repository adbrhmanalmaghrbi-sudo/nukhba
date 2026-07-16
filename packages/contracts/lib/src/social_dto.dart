/// Versioned wire shapes for the Social (Tier-3) context (API ADR §4: DTOs are
/// decoupled from the schema and carry a schema version so client and archived
/// payloads evolve safely).
///
/// These are pure data shapes shared verbatim by client and server; this file
/// depends on nothing (Application ADR §3). Social is a Tier-3 peripheral
/// projection (Database ADR §3) — group-scoped (decision #3, no open graph) and
/// NEVER a source of truth for points (Axiom 5): none of these shapes carry a
/// points-write field or an open-graph edge. The reaction [emoji] and the
/// activity [type] are stable wire tokens (the glyph/label is a client
/// presentation concern), mirroring how `GroupMembershipDto.role` carries a
/// token, not presentation.
library;

/// The wire shape of one reaction (read projection of the domain `Reaction`).
///
/// Names the reaction by [id], its scope ([groupId] + [roundId]), the author
/// [userId], the chosen [emoji] wire token (one of the closed set), and the
/// [reactedAt] UTC ISO-8601 instant. Carries NO points field (Axiom 5) and NO
/// open-graph edge (ADR-001). Versioned.
final class ReactionDto {
  /// Creates a reaction DTO.
  const ReactionDto({
    required this.id,
    required this.groupId,
    required this.roundId,
    required this.userId,
    required this.emoji,
    required this.reactedAt,
    this.schemaVersion = currentSchemaVersion,
  });

  /// Deserializes from a JSON map, defaulting [schemaVersion] for legacy
  /// payloads that predate the field.
  factory ReactionDto.fromJson(Map<String, Object?> json) {
    return ReactionDto(
      schemaVersion: (json['schema_version'] as int?) ?? 1,
      id: json['id']! as String,
      groupId: json['group_id']! as String,
      roundId: json['round_id']! as String,
      userId: json['user_id']! as String,
      emoji: json['emoji']! as String,
      reactedAt: json['reacted_at']! as String,
    );
  }

  /// The current schema version for this DTO.
  static const int currentSchemaVersion = 1;

  /// The reaction id (UUID string).
  final String id;

  /// The group this reaction is scoped to (UUID string).
  final String groupId;

  /// The round-result this reaction targets (UUID string).
  final String roundId;

  /// The reacting member's user id (UUID string).
  final String userId;

  /// The chosen emoji wire token (one of the closed set).
  final String emoji;

  /// When the reaction was made or last changed (UTC ISO-8601).
  final String reactedAt;

  /// The schema version of this payload.
  final int schemaVersion;

  /// Serializes to a JSON-encodable map.
  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'id': id,
    'group_id': groupId,
    'round_id': roundId,
    'user_id': userId,
    'emoji': emoji,
    'reacted_at': reactedAt,
  };

  @override
  bool operator ==(Object other) =>
      other is ReactionDto &&
      other.id == id &&
      other.groupId == groupId &&
      other.roundId == roundId &&
      other.userId == userId &&
      other.emoji == emoji &&
      other.reactedAt == reactedAt &&
      other.schemaVersion == schemaVersion;

  @override
  int get hashCode => Object.hash(
    id,
    groupId,
    roundId,
    userId,
    emoji,
    reactedAt,
    schemaVersion,
  );
}

/// The wire shape of a round's reactions within a group — the response of
/// `GET /groups/{id}/rounds/{roundId}/reactions`.
///
/// Names the scope ([groupId] + [roundId]) and carries the [reactions] in the
/// server-defined order (reactedAt ascending). An empty list is a legitimate
/// result (no member has reacted yet). Versioned.
final class RoundReactionsDto {
  /// Creates a round-reactions DTO.
  const RoundReactionsDto({
    required this.groupId,
    required this.roundId,
    required this.reactions,
    this.schemaVersion = currentSchemaVersion,
  });

  /// Deserializes from a JSON map, defaulting [schemaVersion] for legacy
  /// payloads that predate the field.
  factory RoundReactionsDto.fromJson(Map<String, Object?> json) {
    final raw = json['reactions']! as List<Object?>;
    return RoundReactionsDto(
      schemaVersion: (json['schema_version'] as int?) ?? 1,
      groupId: json['group_id']! as String,
      roundId: json['round_id']! as String,
      reactions: raw
          .map(
            (e) => ReactionDto.fromJson(
              (e! as Map<Object?, Object?>).cast<String, Object?>(),
            ),
          )
          .toList(growable: false),
    );
  }

  /// The current schema version for this DTO.
  static const int currentSchemaVersion = 1;

  /// The group these reactions are scoped to (UUID string).
  final String groupId;

  /// The round-result these reactions target (UUID string).
  final String roundId;

  /// The reactions, in the server-defined order.
  final List<ReactionDto> reactions;

  /// The schema version of this payload.
  final int schemaVersion;

  /// Serializes to a JSON-encodable map.
  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'group_id': groupId,
    'round_id': roundId,
    'reactions': [for (final r in reactions) r.toJson()],
  };

  @override
  bool operator ==(Object other) =>
      other is RoundReactionsDto &&
      other.groupId == groupId &&
      other.roundId == roundId &&
      _listEquals(other.reactions, reactions) &&
      other.schemaVersion == schemaVersion;

  @override
  int get hashCode =>
      Object.hash(groupId, roundId, Object.hashAll(reactions), schemaVersion);

  static bool _listEquals(List<ReactionDto> a, List<ReactionDto> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// The wire shape of one activity-feed event — a read projection assembled from
/// existing ratified data (decision #2: the feed is NOT stored, so this shape is
/// never persisted; it is produced on read).
///
/// The [type] is a stable wire token (`round_scored`/`member_joined`/
/// `rank_shift` — decision #1). [groupId] scopes the event; [occurredAt] is the
/// UTC ISO-8601 instant used for chronological ordering. The remaining fields
/// are type-specific and nullable: [roundId] for `round_scored`, [userId] for
/// `member_joined`/`rank_shift`, and [oldRank]/[newRank] for `rank_shift`.
/// Carries NO points-write field and NO open-graph edge. Versioned.
final class ActivityEventDto {
  /// Creates an activity-event DTO.
  const ActivityEventDto({
    required this.type,
    required this.groupId,
    required this.occurredAt,
    this.roundId,
    this.userId,
    this.oldRank,
    this.newRank,
    this.schemaVersion = currentSchemaVersion,
  });

  /// Deserializes from a JSON map, defaulting [schemaVersion] for legacy
  /// payloads that predate the field.
  factory ActivityEventDto.fromJson(Map<String, Object?> json) {
    return ActivityEventDto(
      schemaVersion: (json['schema_version'] as int?) ?? 1,
      type: json['type']! as String,
      groupId: json['group_id']! as String,
      occurredAt: json['occurred_at']! as String,
      roundId: json['round_id'] as String?,
      userId: json['user_id'] as String?,
      oldRank: json['old_rank'] as int?,
      newRank: json['new_rank'] as int?,
    );
  }

  /// The current schema version for this DTO.
  static const int currentSchemaVersion = 1;

  /// The event type wire token (`round_scored`/`member_joined`/`rank_shift`).
  final String type;

  /// The group this event is scoped to (UUID string).
  final String groupId;

  /// When the event occurred (UTC ISO-8601) — the ordering key.
  final String occurredAt;

  /// The round involved (UUID string), for `round_scored`; else null.
  final String? roundId;

  /// The user involved (UUID string), for `member_joined`/`rank_shift`; else
  /// null.
  final String? userId;

  /// The prior rank, for `rank_shift`; else null.
  final int? oldRank;

  /// The new rank, for `rank_shift`; else null.
  final int? newRank;

  /// The schema version of this payload.
  final int schemaVersion;

  /// Serializes to a JSON-encodable map. Type-specific fields are omitted when
  /// null so the payload stays minimal per event type.
  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'type': type,
    'group_id': groupId,
    'occurred_at': occurredAt,
    if (roundId != null) 'round_id': roundId,
    if (userId != null) 'user_id': userId,
    if (oldRank != null) 'old_rank': oldRank,
    if (newRank != null) 'new_rank': newRank,
  };

  @override
  bool operator ==(Object other) =>
      other is ActivityEventDto &&
      other.type == type &&
      other.groupId == groupId &&
      other.occurredAt == occurredAt &&
      other.roundId == roundId &&
      other.userId == userId &&
      other.oldRank == oldRank &&
      other.newRank == newRank &&
      other.schemaVersion == schemaVersion;

  @override
  int get hashCode => Object.hash(
    type,
    groupId,
    occurredAt,
    roundId,
    userId,
    oldRank,
    newRank,
    schemaVersion,
  );
}

/// The wire shape of a group's activity feed — the response of
/// `GET /groups/{id}/feed`.
///
/// Names the [groupId] and carries the [events] in the server-defined order
/// (occurredAt descending — newest first). An empty list is a legitimate result
/// (a fresh group with no activity yet). Versioned.
final class GroupActivityFeedDto {
  /// Creates a group-activity-feed DTO.
  const GroupActivityFeedDto({
    required this.groupId,
    required this.events,
    this.schemaVersion = currentSchemaVersion,
  });

  /// Deserializes from a JSON map, defaulting [schemaVersion] for legacy
  /// payloads that predate the field.
  factory GroupActivityFeedDto.fromJson(Map<String, Object?> json) {
    final raw = json['events']! as List<Object?>;
    return GroupActivityFeedDto(
      schemaVersion: (json['schema_version'] as int?) ?? 1,
      groupId: json['group_id']! as String,
      events: raw
          .map(
            (e) => ActivityEventDto.fromJson(
              (e! as Map<Object?, Object?>).cast<String, Object?>(),
            ),
          )
          .toList(growable: false),
    );
  }

  /// The current schema version for this DTO.
  static const int currentSchemaVersion = 1;

  /// The group this feed belongs to (UUID string).
  final String groupId;

  /// The events, newest first.
  final List<ActivityEventDto> events;

  /// The schema version of this payload.
  final int schemaVersion;

  /// Serializes to a JSON-encodable map.
  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'group_id': groupId,
    'events': [for (final e in events) e.toJson()],
  };

  @override
  bool operator ==(Object other) =>
      other is GroupActivityFeedDto &&
      other.groupId == groupId &&
      _listEquals(other.events, events) &&
      other.schemaVersion == schemaVersion;

  @override
  int get hashCode =>
      Object.hash(groupId, Object.hashAll(events), schemaVersion);

  static bool _listEquals(List<ActivityEventDto> a, List<ActivityEventDto> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
