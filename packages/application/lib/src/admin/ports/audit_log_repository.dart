import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// Port for the append-only admin audit trail (Application ADR §9: use-cases
/// depend on repository interfaces; Admin Panel decision OPEN-B: ONE general
/// append-only `admin.audit_log` covering ALL admin actions).
///
/// The trail is **append-only** (decision OPEN-B #3): the port deliberately has
/// NO update/delete method — an audit record, once written, is never edited.
/// The physical append-only guarantee is layered (Axiom 6): the app writes only
/// through [append], and the migration revokes update/delete privileges as the
/// backstop.
///
/// General contract (Application ADR §2):
/// * MUST NOT throw — every outcome is a typed [Result].
/// * MUST map infrastructure failures to [ErrorKind.transient].
abstract interface class AuditLogRepository {
  /// Appends one immutable [entry] to the audit trail. Returns `Ok(entry)` on
  /// success. A duplicate-id conflict (the id is server-generated, so this is a
  /// defensive backstop) maps to a typed error; any driver failure maps to
  /// [ErrorKind.transient].
  Future<Result<AuditEntry>> append(AuditEntry entry);

  /// Lists the audit trail newest-first (by `occurredAt` then id), capped at
  /// [limit] rows. An empty trail returns `Ok(<empty>)` (never an error). The
  /// visibility gate (admin-only) lives in the use-case, not here.
  Future<Result<List<AuditEntry>>> list({required int limit});
}
