import 'package:application/src/admin/ports/audit_log_repository.dart';
import 'package:application/src/identity/authorization.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// Query use-case: read the append-only admin audit trail newest-first —
/// **admin-only** (Application ADR §2: query separated from command; Security
/// ADR §2.2: admin/service is the narrowest, most-audited surface).
///
/// The audit trail is itself a privileged surface: only an admin may read it.
/// The gate is the platform role, not membership (Admin Panel decision §2 #2 —
/// existing `PlatformRole.admin`). Steps:
/// 1. authorize the caller as [PlatformRole.admin];
/// 2. clamp an untrusted [limit] to `[1, maxLimit]` (null/non-positive →
///    [defaultLimit]) so a read never triggers an unbounded scan;
/// 3. delegate to [AuditLogRepository.list].
///
/// An empty trail is a legitimate empty result, never an error. Never throws.
final class ListAuditLog {
  /// Creates the use-case over its collaborator.
  const ListAuditLog({required AuditLogRepository auditLog})
    : _auditLog = auditLog;

  final AuditLogRepository _auditLog;

  /// The default page size when no (valid) limit is supplied.
  static const int defaultLimit = 50;

  /// The hard cap on a single audit read (a bounded scan).
  static const int maxLimit = 200;

  /// Returns the audit entries newest-first, visible only to an admin
  /// [principal]. [limit] is clamped defensively.
  Future<Result<List<AuditEntry>>> call({
    required AuthenticatedUser principal,
    int? limit,
  }) async {
    final auth = Authorization.requireRole(principal, PlatformRole.admin);
    if (auth is Err<AuthenticatedUser>) {
      return Result.err(auth.error);
    }
    return _auditLog.list(limit: _clampLimit(limit));
  }

  static int _clampLimit(int? limit) {
    if (limit == null || limit <= 0) return defaultLimit;
    if (limit > maxLimit) return maxLimit;
    return limit;
  }
}
