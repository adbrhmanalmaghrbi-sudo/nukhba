import 'package:shared/shared.dart';

/// The identity of an [AuditEntry] — one immutable, append-only record in the
/// admin audit trail (Admin Panel phase; Security ADR 0006 §2.2: admin/service
/// is the "narrowest, most-audited surface"; §2.4/§4: every privileged action
/// leaves an immutable, attributable trace).
///
/// A value object (Coding Standards ADR, Section 2), canonically a UUID matching
/// the `admin.audit_log` primary key. Kept a distinct id type from every other
/// aggregate id so an audit row is never addressed by a user, round, group,
/// notification, or reaction id by mistake.
final class AuditEntryId extends EntityId {
  /// Creates an [AuditEntryId] from its canonical UUID string.
  ///
  /// Callers that receive untrusted input should use [tryParse], which validates
  /// shape and returns a typed [Result] rather than constructing an id that
  /// might be empty or malformed.
  const AuditEntryId(super.value);

  /// Parses an [AuditEntryId] from an untrusted [raw] string, returning a
  /// validation [AppError] when it is absent or not a canonical (hyphenated,
  /// 36-char) UUID.
  static Result<AuditEntryId> tryParse(String? raw) {
    if (raw == null || raw.isEmpty) {
      return const Result.err(
        AppError.validation(
          'admin.audit_entry_id_empty',
          'Audit entry id is required',
        ),
      );
    }
    if (!_uuid.hasMatch(raw)) {
      return const Result.err(
        AppError.validation(
          'admin.audit_entry_id_malformed',
          'Audit entry id must be a UUID',
        ),
      );
    }
    return Result.ok(AuditEntryId(raw));
  }

  /// Canonical UUID form: 8-4-4-4-12 hexadecimal, case-insensitive.
  static final RegExp _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
    r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );
}
