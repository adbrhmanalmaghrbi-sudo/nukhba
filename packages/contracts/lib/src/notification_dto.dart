/// Versioned wire shapes for the Notifications (Tier-3) context (API ADR §4:
/// DTOs are decoupled from the schema and carry a schema version so client and
/// archived payloads evolve safely).
///
/// These are pure data shapes shared verbatim by client and server; this file
/// depends on nothing (Application ADR §3). Notifications is a Tier-3 peripheral
/// aggregate (Database ADR §3) — recipient-scoped (decision #4) and NEVER a
/// source of truth for points (Axiom 5): none of these shapes carry a
/// points-write field or an open-graph edge. The notification [kind] is a
/// stable wire token (the copy/glyph is a client presentation concern),
/// mirroring how `ReactionDto.emoji` / `GroupMembershipDto.role` carry tokens,
/// not presentation.
library;

/// The wire shape of one notification (read projection of the domain
/// `Notification`).
///
/// Names the notification by [id], its single [recipientId], the [kind] wire
/// token (one of the closed set), the [read] flag + optional [readAt] instant,
/// the [createdAt] UTC ISO-8601 instant, and the kind-specific nullable subject
/// references ([roundId]/[groupId]/[actorUserId]) that let a client render and
/// deep-link the notification. Null subject fields are omitted from JSON so the
/// payload stays minimal per kind. Carries NO points field (Axiom 5) and NO
/// open-graph edge (ADR-001). Versioned.
final class NotificationDto {
  /// Creates a notification DTO.
  const NotificationDto({
    required this.id,
    required this.recipientId,
    required this.kind,
    required this.read,
    required this.createdAt,
    this.readAt,
    this.roundId,
    this.groupId,
    this.actorUserId,
    this.schemaVersion = currentSchemaVersion,
  });

  /// Deserializes from a JSON map, defaulting [schemaVersion] for legacy
  /// payloads that predate the field.
  factory NotificationDto.fromJson(Map<String, Object?> json) {
    return NotificationDto(
      schemaVersion: (json['schema_version'] as int?) ?? 1,
      id: json['id']! as String,
      recipientId: json['recipient_id']! as String,
      kind: json['kind']! as String,
      read: json['read']! as bool,
      createdAt: json['created_at']! as String,
      readAt: json['read_at'] as String?,
      roundId: json['round_id'] as String?,
      groupId: json['group_id'] as String?,
      actorUserId: json['actor_user_id'] as String?,
    );
  }

  /// The current schema version for this DTO.
  static const int currentSchemaVersion = 1;

  /// The notification id (UUID string).
  final String id;

  /// The single recipient's user id (UUID string).
  final String recipientId;

  /// The kind wire token (`round_scored`/`group_member_joined`/
  /// `reaction_received`).
  final String kind;

  /// Whether the recipient has read this notification.
  final bool read;

  /// When it was created (UTC ISO-8601) — the newest-first ordering key.
  final String createdAt;

  /// When it was read (UTC ISO-8601), or null while unread.
  final String? readAt;

  /// The round involved (UUID string), for `round_scored`/`reaction_received`;
  /// else null.
  final String? roundId;

  /// The group involved (UUID string), for `group_member_joined`/
  /// `reaction_received`; else null.
  final String? groupId;

  /// The acting user (UUID string) — the joiner or reactor — for
  /// `group_member_joined`/`reaction_received`; else null.
  final String? actorUserId;

  /// The schema version of this payload.
  final int schemaVersion;

  /// Serializes to a JSON-encodable map. Null subject fields (and [readAt] while
  /// unread) are omitted so the payload stays minimal per kind.
  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'id': id,
    'recipient_id': recipientId,
    'kind': kind,
    'read': read,
    'created_at': createdAt,
    if (readAt != null) 'read_at': readAt,
    if (roundId != null) 'round_id': roundId,
    if (groupId != null) 'group_id': groupId,
    if (actorUserId != null) 'actor_user_id': actorUserId,
  };

  @override
  bool operator ==(Object other) =>
      other is NotificationDto &&
      other.id == id &&
      other.recipientId == recipientId &&
      other.kind == kind &&
      other.read == read &&
      other.createdAt == createdAt &&
      other.readAt == readAt &&
      other.roundId == roundId &&
      other.groupId == groupId &&
      other.actorUserId == actorUserId &&
      other.schemaVersion == schemaVersion;

  @override
  int get hashCode => Object.hash(
    id,
    recipientId,
    kind,
    read,
    createdAt,
    readAt,
    roundId,
    groupId,
    actorUserId,
    schemaVersion,
  );
}

/// The wire shape of a recipient's notification list — the response of
/// `GET /notifications`.
///
/// Names the [recipientId] and carries the [notifications] in the server-defined
/// order (createdAt descending — newest first) plus the [unreadCount] across the
/// recipient's whole inbox (not just the returned page). An empty list is a
/// legitimate result (a recipient with no notifications). Versioned.
final class NotificationListDto {
  /// Creates a notification-list DTO.
  const NotificationListDto({
    required this.recipientId,
    required this.notifications,
    required this.unreadCount,
    this.schemaVersion = currentSchemaVersion,
  });

  /// Deserializes from a JSON map, defaulting [schemaVersion] for legacy
  /// payloads that predate the field.
  factory NotificationListDto.fromJson(Map<String, Object?> json) {
    final raw = json['notifications']! as List<Object?>;
    return NotificationListDto(
      schemaVersion: (json['schema_version'] as int?) ?? 1,
      recipientId: json['recipient_id']! as String,
      unreadCount: json['unread_count']! as int,
      notifications: raw
          .map(
            (e) => NotificationDto.fromJson(
              (e! as Map<Object?, Object?>).cast<String, Object?>(),
            ),
          )
          .toList(growable: false),
    );
  }

  /// The current schema version for this DTO.
  static const int currentSchemaVersion = 1;

  /// The recipient this list belongs to (UUID string).
  final String recipientId;

  /// The notifications, newest first.
  final List<NotificationDto> notifications;

  /// The recipient's total unread count across their whole inbox.
  final int unreadCount;

  /// The schema version of this payload.
  final int schemaVersion;

  /// Serializes to a JSON-encodable map.
  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'recipient_id': recipientId,
    'unread_count': unreadCount,
    'notifications': [for (final n in notifications) n.toJson()],
  };

  @override
  bool operator ==(Object other) =>
      other is NotificationListDto &&
      other.recipientId == recipientId &&
      other.unreadCount == unreadCount &&
      _listEquals(other.notifications, notifications) &&
      other.schemaVersion == schemaVersion;

  @override
  int get hashCode => Object.hash(
    recipientId,
    unreadCount,
    Object.hashAll(notifications),
    schemaVersion,
  );

  static bool _listEquals(List<NotificationDto> a, List<NotificationDto> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
