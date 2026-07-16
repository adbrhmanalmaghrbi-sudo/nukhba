/// Versioned wire shapes for the Admin Panel context (API ADR §4: DTOs are
/// decoupled from the schema and carry a schema version so client and archived
/// payloads evolve safely).
///
/// These are pure data shapes shared verbatim by client and server; this file
/// depends on nothing (Application ADR §3).
///
/// Integrity boundary (Axioms 2/5; Admin Panel decisions OPEN-A/OPEN-B):
///   * The ONLY client-supplied admin command body in v1 is the mandatory
///     sanction **reason** ([SuspendUserRequestDto]) — a suspend/reinstate
///     action carries who-did-what-why for the audit trail; it never carries a
///     point amount or a target id in the body (the target user id travels in
///     the path, the actor is bound from the verified token server-side).
///   * The audit trail is a **read-only** surface on the wire
///     ([AuditEntryDto] / [AuditLogDto]) — every field is server-produced from
///     the append-only `admin.audit_log`; there is deliberately no command DTO
///     that writes an audit row (audit entries are a side effect of a
///     privileged action, never directly authored by a client).
///   * No DTO here adds a group reference onto any core object (Axiom 4) or
///     carries a points field (Axiom 5).
library;

/// The request body of a user-suspension command
/// (`POST /admin/users/{id}/suspend`). The target user id is in the path and
/// the acting admin is bound from the verified token; the ONLY client-supplied
/// value is the mandatory [reason] (Admin Panel decision OPEN-A #1: every
/// suspend carries a reason, recorded in the audit trail — decision OPEN-B).
///
/// Reinstatement (`POST /admin/users/{id}/reinstate`) reuses this same shape:
/// a reason is likewise mandatory so the reversal is equally attributable.
final class SuspendUserRequestDto {
  /// Creates a suspend/reinstate request body.
  const SuspendUserRequestDto({
    required this.reason,
    this.schemaVersion = currentSchemaVersion,
  });

  /// Deserializes from a JSON map, defaulting [schemaVersion] for legacy
  /// payloads that predate the field. A missing `reason` surfaces as an
  /// explicit `null` so the use-case reports the validation failure (never a
  /// silent empty sanction).
  factory SuspendUserRequestDto.fromJson(Map<String, Object?> json) {
    return SuspendUserRequestDto(
      schemaVersion: (json['schema_version'] as int?) ?? 1,
      reason: json['reason'] as String?,
    );
  }

  /// The current schema version for this DTO.
  static const int currentSchemaVersion = 1;

  /// The mandatory justification for the sanction. Nullable on the wire only so
  /// a malformed body (missing field) can be reported as a validation failure
  /// by the use-case rather than throwing at parse time.
  final String? reason;

  /// The schema version of this payload.
  final int schemaVersion;

  /// Serializes to a JSON-encodable map.
  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'reason': reason,
  };

  @override
  bool operator ==(Object other) =>
      other is SuspendUserRequestDto &&
      other.reason == reason &&
      other.schemaVersion == schemaVersion;

  @override
  int get hashCode => Object.hash(reason, schemaVersion);
}

/// The wire shape echoed back after an admin suspends or reinstates a user
/// (`POST /admin/users/{id}/suspend` | `.../reinstate`). Reports the target
/// user's new lifecycle [status] (`active` / `suspended`, matching
/// `UserStatus.name`) — a server-produced value confirming the transition
/// (idempotent: re-suspending an already-suspended user echoes `suspended`).
/// Carries NO points field (Axiom 5).
final class UserSanctionResultDto {
  /// Creates a user-sanction result DTO.
  const UserSanctionResultDto({
    required this.userId,
    required this.status,
    this.schemaVersion = currentSchemaVersion,
  });

  /// Deserializes from a JSON map, defaulting [schemaVersion] for legacy
  /// payloads that predate the field.
  factory UserSanctionResultDto.fromJson(Map<String, Object?> json) {
    return UserSanctionResultDto(
      schemaVersion: (json['schema_version'] as int?) ?? 1,
      userId: json['user_id']! as String,
      status: json['status']! as String,
    );
  }

  /// The current schema version for this DTO.
  static const int currentSchemaVersion = 1;

  /// The target user (UUID string).
  final String userId;

  /// The user's resulting lifecycle status (`active` / `suspended`).
  final String status;

  /// The schema version of this payload.
  final int schemaVersion;

  /// Serializes to a JSON-encodable map.
  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'user_id': userId,
    'status': status,
  };

  @override
  bool operator ==(Object other) =>
      other is UserSanctionResultDto &&
      other.userId == userId &&
      other.status == status &&
      other.schemaVersion == schemaVersion;

  @override
  int get hashCode => Object.hash(userId, status, schemaVersion);
}

/// The wire shape of one immutable admin audit record (read projection of the
/// domain `AuditEntry`) — an element of `GET /admin/audit`.
///
/// Answers who-did-what-to-which-entity-when-and-why: [actorId] (the acting
/// admin), [action] (the stable wire token matching `AuditAction.wireValue`,
/// e.g. `user_suspended` — never a Dart enum name so a persisted value can
/// never drift), [targetRef] (the opaque provenance reference to the entity
/// acted on), [reason] (present for a sanction, `null`/omitted otherwise), and
/// [occurredAt] (ISO-8601 UTC). Every field is server-produced (append-only —
/// no client ever writes an audit row); carries NO points field (Axiom 5).
final class AuditEntryDto {
  /// Creates an audit-entry DTO.
  const AuditEntryDto({
    required this.id,
    required this.actorId,
    required this.action,
    required this.targetRef,
    required this.occurredAt,
    this.reason,
    this.schemaVersion = currentSchemaVersion,
  });

  /// Deserializes from a JSON map, defaulting [schemaVersion] for legacy
  /// payloads that predate the field. A `null`/absent `reason` stays `null`.
  factory AuditEntryDto.fromJson(Map<String, Object?> json) {
    return AuditEntryDto(
      schemaVersion: (json['schema_version'] as int?) ?? 1,
      id: json['id']! as String,
      actorId: json['actor_id']! as String,
      action: json['action']! as String,
      targetRef: json['target_ref']! as String,
      reason: json['reason'] as String?,
      occurredAt: json['occurred_at']! as String,
    );
  }

  /// The current schema version for this DTO.
  static const int currentSchemaVersion = 1;

  /// The audit entry's own id (UUID string).
  final String id;

  /// The acting admin's platform user id (attributability — UUID string).
  final String actorId;

  /// The action wire token (`user_suspended`, `round_scored`, …). Matches
  /// `AuditAction.wireValue` in the domain.
  final String action;

  /// The opaque reference to the entity acted on (provenance, not a foreign
  /// key).
  final String targetRef;

  /// The justification (present for a sanction; `null` when the action carried
  /// none). Omitted from JSON when `null`.
  final String? reason;

  /// When the action happened (ISO-8601 UTC string).
  final String occurredAt;

  /// The schema version of this payload.
  final int schemaVersion;

  /// Serializes to a JSON-encodable map. The `reason` key is omitted entirely
  /// when `null` (matching the domain's optional-reason shape).
  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'id': id,
    'actor_id': actorId,
    'action': action,
    'target_ref': targetRef,
    if (reason != null) 'reason': reason,
    'occurred_at': occurredAt,
  };

  @override
  bool operator ==(Object other) =>
      other is AuditEntryDto &&
      other.id == id &&
      other.actorId == actorId &&
      other.action == action &&
      other.targetRef == targetRef &&
      other.reason == reason &&
      other.occurredAt == occurredAt &&
      other.schemaVersion == schemaVersion;

  @override
  int get hashCode => Object.hash(
    id,
    actorId,
    action,
    targetRef,
    reason,
    occurredAt,
    schemaVersion,
  );
}

/// The wire shape of the admin audit trail (read projection of the append-only
/// `admin.audit_log`) — the response of `GET /admin/audit`. A pure read
/// projection ordered newest-first by the server; visibility (admin-only) is
/// gated in the use-case, not this shape. An empty [entries] list is a
/// legitimate empty trail, never an error.
final class AuditLogDto {
  /// Creates an audit-log DTO.
  const AuditLogDto({
    required this.entries,
    this.schemaVersion = currentSchemaVersion,
  });

  /// Deserializes from a JSON map, defaulting [schemaVersion] for legacy
  /// payloads that predate the field.
  factory AuditLogDto.fromJson(Map<String, Object?> json) {
    final raw = json['entries']! as List<Object?>;
    return AuditLogDto(
      schemaVersion: (json['schema_version'] as int?) ?? 1,
      entries: raw
          .map(
            (e) => AuditEntryDto.fromJson(
              (e! as Map<Object?, Object?>).cast<String, Object?>(),
            ),
          )
          .toList(growable: false),
    );
  }

  /// The current schema version for this DTO.
  static const int currentSchemaVersion = 1;

  /// The audit entries, newest-first (server-defined order).
  final List<AuditEntryDto> entries;

  /// The schema version of this payload.
  final int schemaVersion;

  /// Serializes to a JSON-encodable map.
  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'entries': [for (final e in entries) e.toJson()],
  };

  @override
  bool operator ==(Object other) =>
      other is AuditLogDto &&
      _listEquals(other.entries, entries) &&
      other.schemaVersion == schemaVersion;

  @override
  int get hashCode => Object.hash(Object.hashAll(entries), schemaVersion);

  static bool _listEquals(List<AuditEntryDto> a, List<AuditEntryDto> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
