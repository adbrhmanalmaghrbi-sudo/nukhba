import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:infrastructure/src/db/postgres_connection.dart';
// `postgres` exports its own `Result`; we only need its exception hierarchy
// here (to read the SQLSTATE `code`/`constraintName` off a `ServerException`),
// so hide `Result` to keep `Result<T>` unambiguously our `shared` union.
import 'package:postgres/postgres.dart' hide Result;
import 'package:shared/shared.dart';

/// Postgres-backed [AuditLogRepository] over the append-only `admin.audit_log`
/// table (Database ADR; migration `0010_admin.sql`; Admin Panel decision
/// OPEN-B: ONE general append-only trail covering ALL admin actions).
///
/// The trail is **append-only** (decision OPEN-B #3): this adapter offers only
/// [append] and [list] — never an update or delete. The physical append-only
/// guarantee is layered (Axiom 6): the app writes only through [append], and
/// the migration revokes UPDATE/DELETE/TRUNCATE from every role and installs an
/// immutability trigger as the backstop.
///
/// The adapter is *total* (Application ADR §2): it never throws. It speaks only
/// in the domain [AuditEntry] aggregate and typed ids; SQL and rows never leak.
/// A driver failure is surfaced as [ErrorKind.transient]; a malformed row is
/// mapped to a transient `admin.audit_row_corrupt`. All queries bind values
/// through `@named` parameters (Security ADR §2).
///
/// The id is generated server-side by the use-case (`AuditRecorder` via
/// `IdGenerator`), so a primary-key conflict is a defensive backstop only: the
/// constraint name `audit_log_pkey` is part of this adapter's contract — the
/// SQLSTATE 23505 → typed-error map keys off it, so it MUST NOT be renamed
/// without updating this adapter in lockstep. An `actor_id` that names no
/// `identity.users` row is the other integrity path (`23503` on
/// `audit_log_actor_id_fkey`).
final class PostgresAuditLogRepository implements AuditLogRepository {
  /// Creates the repository over an open [PostgresConnection].
  const PostgresAuditLogRepository(this._connection);

  final PostgresConnection _connection;

  // --------------------------------------------------------------------------
  // append — write one immutable audit row
  // --------------------------------------------------------------------------

  // A plain INSERT: the row is immutable once written (no ON CONFLICT — a
  // duplicate id is not an expected replay here, unlike notifications; it is a
  // defensive backstop mapped to a typed error). reason is nullable (an action
  // that carries none stores NULL; a sanction always supplies one). occurred_at
  // is stored UTC — the newest-first ordering key for the audit read.
  static const String _appendSql = '''
INSERT INTO admin.audit_log
  (id, actor_id, action, target_ref, reason, occurred_at)
VALUES
  (@id, @actor_id, @action, @target_ref, @reason, @occurred_at)
RETURNING id
''';

  @override
  Future<Result<AuditEntry>> append(AuditEntry entry) async {
    final result = await _connection.query(
      _appendSql,
      parameters: {
        'id': entry.id.value,
        'actor_id': entry.actorId.value,
        'action': entry.action.wireValue,
        'target_ref': entry.targetRef,
        'reason': entry.reason,
        'occurred_at': entry.occurredAt.toUtc(),
      },
    );
    return switch (result) {
      Err<List<Map<String, dynamic>>>(:final error) => Result.err(
        _reclassify(error),
      ),
      // A returned row confirms the append; RETURNING id always yields exactly
      // one row for a successful INSERT, so echo back the entry we stored.
      Ok<List<Map<String, dynamic>>>(:final value) =>
        value.isEmpty
            ? const Result.err(
                AppError.transient(
                  'admin.audit_append_no_row',
                  'Audit append returned no row',
                ),
              )
            : Result.ok(entry),
    };
  }

  // --------------------------------------------------------------------------
  // list — the audit trail newest-first, capped at limit
  // --------------------------------------------------------------------------

  static const String _listSql = '''
SELECT id, actor_id, action, target_ref, reason, occurred_at
FROM admin.audit_log
ORDER BY occurred_at DESC, id DESC
LIMIT @limit
''';

  @override
  Future<Result<List<AuditEntry>>> list({required int limit}) async {
    final result = await _connection.query(
      _listSql,
      parameters: {'limit': limit},
    );
    return switch (result) {
      Err<List<Map<String, dynamic>>>(:final error) => Result.err(error),
      Ok<List<Map<String, dynamic>>>(:final value) => _mapMany(value),
    };
  }

  // --------------------------------------------------------------------------
  // Row mapping
  // --------------------------------------------------------------------------

  Result<List<AuditEntry>> _mapMany(List<Map<String, dynamic>> rows) {
    final entries = <AuditEntry>[];
    for (final row in rows) {
      final mapped = _mapOne(row);
      if (mapped is Err<AuditEntry>) {
        return Result.err(mapped.error);
      }
      entries.add((mapped as Ok<AuditEntry>).value);
    }
    return Result.ok(List<AuditEntry>.unmodifiable(entries));
  }

  Result<AuditEntry> _mapOne(Map<String, dynamic> row) {
    final idResult = AuditEntryId.tryParse(row['id']?.toString());
    if (idResult is Err<AuditEntryId>) {
      return Result.err(_corrupt('id', idResult.error.message));
    }
    final actorResult = UserId.tryParse(row['actor_id']?.toString());
    if (actorResult is Err<UserId>) {
      return Result.err(_corrupt('actor_id', actorResult.error.message));
    }
    final actionResult = AuditAction.tryParse(row['action']?.toString());
    if (actionResult is Err<AuditAction>) {
      return Result.err(_corrupt('action', actionResult.error.message));
    }
    final occurredAt = _readUtcTimestamp(row['occurred_at']);
    if (occurredAt == null) {
      return Result.err(_corrupt('occurred_at', 'not a timestamp'));
    }

    // target_ref is NOT NULL in the schema; guard defensively anyway so a
    // corrupt NULL surfaces as a typed transient rather than a cast throw.
    final targetRef = row['target_ref'];
    if (targetRef is! String || targetRef.isEmpty) {
      return Result.err(_corrupt('target_ref', 'missing or empty'));
    }

    // reason is nullable; a present value must be a String.
    String? reason;
    final rawReason = row['reason'];
    if (rawReason != null) {
      if (rawReason is! String) {
        return Result.err(_corrupt('reason', 'not text'));
      }
      reason = rawReason;
    }

    // fromStored performs only typing — the row is already trusted storage.
    return Result.ok(
      AuditEntry.fromStored(
        id: (idResult as Ok<AuditEntryId>).value,
        actorId: (actorResult as Ok<UserId>).value,
        action: (actionResult as Ok<AuditAction>).value,
        targetRef: targetRef,
        reason: reason,
        occurredAt: occurredAt,
      ),
    );
  }

  // --------------------------------------------------------------------------
  // SQLSTATE reclassification (mirror the notification/ledger adapters)
  // --------------------------------------------------------------------------

  AppError _reclassify(AppError error) {
    final cause = error.cause;
    if (cause is! ServerException) {
      return error;
    }
    final code = cause.code;
    // 23505 unique_violation (a duplicate server-generated id — a defensive
    // backstop, never an expected replay), 23503 foreign_key_violation (the
    // acting admin's user row vanished).
    const integrityCodes = {'23505', '23503'};
    if (code == null || !integrityCodes.contains(code)) {
      return error;
    }
    final constraint = cause.constraintName;
    if (constraint == 'audit_log_pkey') {
      return const AppError.invariant(
        'admin.audit_duplicate',
        'An audit entry with this id already exists',
      );
    }
    if (constraint == 'audit_log_actor_id_fkey') {
      return const AppError.invariant(
        'admin.audit_actor_not_found',
        'The acting admin user was not found',
      );
    }
    return const AppError.invariant(
      'admin.audit_integrity_violation',
      'The write violated an audit-log integrity rule',
    );
  }

  static DateTime? _readUtcTimestamp(Object? raw) {
    if (raw is DateTime) {
      return raw.toUtc();
    }
    if (raw is String) {
      final parsed = DateTime.tryParse(raw);
      return parsed?.toUtc();
    }
    return null;
  }

  static AppError _corrupt(String field, String detail) => AppError.transient(
    'admin.audit_row_corrupt',
    'Stored admin.audit_log row has invalid $field: $detail',
  );
}
