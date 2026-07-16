import 'package:application/src/admin/ports/audit_log_repository.dart';
import 'package:application/src/common/clock.dart';
import 'package:application/src/common/id_generator.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// The single server-side path that writes one [AuditEntry] to the append-only
/// trail — the audit analogue of the Notification phase's `CreateNotification`
/// facade (one write path, so every admin use-case depends on one thing).
///
/// It is NOT client-callable and carries no self-role gate: it is invoked by an
/// admin use-case that has ALREADY authorized the caller as
/// [PlatformRole.admin]. It generates the [AuditEntryId] server-side
/// ([IdGenerator]), stamps `occurredAt` from the injected [Clock] (UTC), builds
/// the immutable [AuditEntry] via `AuditEntry.create` (which validates the
/// non-blank/length-bounded [reason] and the non-blank target), and appends it
/// via [AuditLogRepository.append].
///
/// Returns the persisted [AuditEntry], or the typed error to propagate. Never
/// throws (Application ADR §2). Unlike Notifications' best-effort Tier-3
/// degradation, the audit write is NOT optional for a crown-jewel admin action:
/// a caller that must not proceed without a recorded trace propagates this
/// error rather than swallowing it (Security ADR §2.4).
final class AuditRecorder {
  /// Creates the recorder over its collaborators.
  const AuditRecorder({
    required AuditLogRepository auditLog,
    required IdGenerator idGenerator,
    required Clock clock,
  }) : _auditLog = auditLog,
       _idGenerator = idGenerator,
       _clock = clock;

  final AuditLogRepository _auditLog;
  final IdGenerator _idGenerator;
  final Clock _clock;

  /// Records that [actorId] performed [action] on [targetRef], optionally with
  /// [reason]. The caller is responsible for having authorized the actor and
  /// for supplying a [reason] where the action mandates one (e.g. a sanction);
  /// `AuditEntry.create` still rejects a supplied-but-blank reason.
  Future<Result<AuditEntry>> record({
    required UserId actorId,
    required AuditAction action,
    required String targetRef,
    String? reason,
  }) async {
    final idResult = AuditEntryId.tryParse(_idGenerator.newUuid());
    if (idResult is Err<AuditEntryId>) {
      return Result.err(idResult.error);
    }
    final id = (idResult as Ok<AuditEntryId>).value;

    final built = AuditEntry.create(
      id: id,
      actorId: actorId,
      action: action,
      targetRef: targetRef,
      occurredAt: _clock.nowUtc(),
      reason: reason,
    );
    if (built is Err<AuditEntry>) {
      return Result.err(built.error);
    }
    final entry = (built as Ok<AuditEntry>).value;

    return _auditLog.append(entry);
  }
}
