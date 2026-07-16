import 'package:domain/src/admin/audit_action.dart';
import 'package:domain/src/admin/audit_entry_id.dart';
import 'package:domain/src/identity/user_id.dart';
import 'package:shared/shared.dart';

/// One immutable, append-only record of a privileged admin action — the single
/// unit of the admin audit trail (Admin Panel decision OPEN-B: ONE general
/// append-only `admin.audit_log`, covering ALL admin actions, append-only only;
/// Security ADR 0006 §2.2/§2.4/§4: the crown-jewel record cannot be altered by
/// anyone, including an admin, without an immutable, attributable trace).
///
/// An [AuditEntry] answers **who did what, to which entity, when, and why**:
///   * [actorId]   — the acting admin's platform [UserId] (bound from the
///                   verified token by the use-case, never a body — Security
///                   ADR §2). This is the attributability the ADR requires.
///   * [action]    — the closed [AuditAction] discriminant.
///   * [targetRef] — an opaque, human-readable reference to the entity acted on
///                   (e.g. a user id, round id, participant id, or a composite
///                   like `round:<id>`). Deliberately a free-form-but-bounded
///                   string rather than a typed id union, because different
///                   actions target different aggregates; it is provenance, not
///                   a foreign key (the audit log never constrains the entities
///                   it observes — it is peripheral to them).
///   * [reason]    — the mandatory justification for a sanction (decision
///                   OPEN-A #1: every suspend carries a reason), optional for
///                   actions where the ADRs impose none. When required, the
///                   use-case validates its presence before constructing the
///                   entry; [create] enforces non-blank when a reason is given.
///   * [occurredAt]— the UTC instant of the action (the newest-first ordering
///                   key for the audit read).
///
/// Pure and immutable — there is NO mutation API at all (an audit record, once
/// written, is never edited; the append-only guarantee is physical in the
/// migration too — write-privilege revocation + no update/delete). It carries
/// NO points field (Axiom 5) and adds NO reference onto any core aggregate
/// (the link is FROM the audit log TO an opaque ref, never the reverse).
/// Value-comparable.
final class AuditEntry {
  const AuditEntry._({
    required this.id,
    required this.actorId,
    required this.action,
    required this.targetRef,
    required this.reason,
    required this.occurredAt,
  });

  /// Rehydrates an [AuditEntry] from already-trusted stored fields (used by the
  /// infrastructure mapper). Performs no validation beyond typing.
  const AuditEntry.fromStored({
    required this.id,
    required this.actorId,
    required this.action,
    required this.targetRef,
    required this.reason,
    required this.occurredAt,
  });

  /// Creates a new audit entry from validated inputs.
  ///
  /// [id] and [actorId] are already validated value objects. [occurredAt] must
  /// be UTC (callers normalize) so the append-only stream orders unambiguously.
  /// [targetRef] must be a non-blank reference (an audit record always names the
  /// entity it concerns). [reason], when supplied, must be non-blank — a blank
  /// reason is a validation failure so a sanction can never be recorded with an
  /// empty justification (decision OPEN-A #1). A `null` [reason] is allowed for
  /// actions that carry none; the use-case decides whether a reason is mandatory
  /// for a given [action] (e.g. `SuspendUser` requires one) before calling this.
  static Result<AuditEntry> create({
    required AuditEntryId id,
    required UserId actorId,
    required AuditAction action,
    required String targetRef,
    required DateTime occurredAt,
    String? reason,
  }) {
    if (!occurredAt.isUtc) {
      return const Result.err(
        AppError.validation(
          'admin.audit_occurred_at_not_utc',
          'occurredAt must be provided in UTC',
        ),
      );
    }
    final trimmedTarget = targetRef.trim();
    if (trimmedTarget.isEmpty) {
      return const Result.err(
        AppError.validation(
          'admin.audit_target_ref_empty',
          'An audit entry must reference the entity it concerns',
        ),
      );
    }
    String? trimmedReason;
    if (reason != null) {
      final t = reason.trim();
      if (t.isEmpty) {
        return const Result.err(
          AppError.validation(
            'admin.audit_reason_empty',
            'A supplied audit reason must not be blank',
          ),
        );
      }
      if (t.length > maxReasonLength) {
        return const Result.err(
          AppError.validation(
            'admin.audit_reason_too_long',
            'An audit reason must be at most $maxReasonLength characters',
          ),
        );
      }
      trimmedReason = t;
    }
    return Result.ok(
      AuditEntry._(
        id: id,
        actorId: actorId,
        action: action,
        targetRef: trimmedTarget,
        reason: trimmedReason,
        occurredAt: occurredAt,
      ),
    );
  }

  /// The maximum length of a stored audit reason (a bounded free-text
  /// justification; keeps the append-only row size predictable).
  static const int maxReasonLength = 500;

  /// The audit entry identity.
  final AuditEntryId id;

  /// The acting admin's platform user id (attributability — Security ADR §2.4).
  final UserId actorId;

  /// What the admin did (closed discriminant).
  final AuditAction action;

  /// An opaque reference to the entity acted on (provenance, not a foreign key).
  final String targetRef;

  /// The justification, non-blank when present; required by the use-case for a
  /// sanction (decision OPEN-A #1), else optional.
  final String? reason;

  /// When the action happened (UTC) — the newest-first ordering key.
  final DateTime occurredAt;

  @override
  bool operator ==(Object other) =>
      other is AuditEntry &&
      other.id == id &&
      other.actorId == actorId &&
      other.action == action &&
      other.targetRef == targetRef &&
      other.reason == reason &&
      other.occurredAt == occurredAt;

  @override
  int get hashCode =>
      Object.hash(id, actorId, action, targetRef, reason, occurredAt);

  @override
  String toString() =>
      'AuditEntry(${id.value}, ${action.wireValue}, '
      'actor: ${actorId.value}, target: $targetRef)';
}
