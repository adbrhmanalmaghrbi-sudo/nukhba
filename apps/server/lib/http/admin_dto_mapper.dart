import 'package:contracts/contracts.dart';
import 'package:domain/domain.dart';

/// Projects the domain Admin read/command values onto their versioned wire
/// shapes (API ADR §4), in one place, so every admin response shapes a value
/// identically.
///
/// Integrity boundary (Axioms 2/5; Admin Panel decisions OPEN-A/OPEN-B): every
/// value here is **server-produced** — a user's resulting sanction status and
/// the append-only audit records are echoed exactly as the domain
/// produced/stored them; nothing here is client-writable and there is no
/// inverse (a client never sends a sanction result or an audit row). The audit
/// [action] crosses the wire as its stable [AuditAction.wireValue] token
/// (`user_suspended`, `round_scored`, …), never a Dart enum name, so a
/// persisted value can never drift silently. The [occurredAt] instant is
/// emitted as an ISO-8601 UTC string. Carries NO points field (Axiom 5).

/// Shapes the response of `POST /admin/users/{id}/suspend` |
/// `.../reinstate` — the target user's id plus their resulting lifecycle
/// status (`active` / `suspended`, matching `UserStatus.name`). Idempotent:
/// re-suspending an already-suspended user echoes `suspended`.
Map<String, Object?> userSanctionResultJson(User user) {
  return UserSanctionResultDto(
    userId: user.id.value,
    status: user.status.name,
  ).toJson();
}

/// Projects one immutable [AuditEntry] onto the wire [AuditEntryDto].
///
/// The `reason` is carried through as-is (`null` for an action that carried
/// none — the DTO omits the key entirely when null). `action` crosses as its
/// stable wire token; `occurredAt` as an ISO-8601 UTC string.
AuditEntryDto auditEntryToDto(AuditEntry entry) {
  return AuditEntryDto(
    id: entry.id.value,
    actorId: entry.actorId.value,
    action: entry.action.wireValue,
    targetRef: entry.targetRef,
    reason: entry.reason,
    // Always UTC (the domain AuditEntry.create enforces isUtc); ISO-8601.
    occurredAt: entry.occurredAt.toUtc().toIso8601String(),
  );
}

/// Shapes the response of `GET /admin/audit` — the append-only admin audit
/// trail, newest-first (the server-defined order the use-case/repository
/// produced). An empty [entries] list is a legitimate empty trail, never an
/// error.
Map<String, Object?> auditLogJson(List<AuditEntry> entries) {
  return AuditLogDto(
    entries: [for (final entry in entries) auditEntryToDto(entry)],
  ).toJson();
}
