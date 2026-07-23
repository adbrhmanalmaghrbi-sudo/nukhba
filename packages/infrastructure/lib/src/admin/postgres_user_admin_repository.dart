import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:infrastructure/src/db/postgres_connection.dart';
// `postgres` exports its own `Result`; we only need its exception hierarchy
// here (to read the SQLSTATE `code` off a `ServerException`), so hide `Result`
// to keep `Result<T>` unambiguously our `shared` union.
import 'package:postgres/postgres.dart' hide Result;
import 'package:shared/shared.dart';

/// Postgres-backed [UserAdminRepository] over the canonical `identity.users`
/// table (Database ADR §3; migration `0001_identity.sql`) — the admin
/// user-sanction surface's storage adapter (Admin Panel decision OPEN-A #1;
/// §4 Q2/Q3).
///
/// The ratified `UserDirectory` (`PostgresUserDirectory`) only knows how to
/// *ensure* the caller's own row from a verified principal; it has no
/// "find an arbitrary user by id" or "update another user's status" capability,
/// and widening that frozen port would violate the no-change-without-approval
/// rule (Roadmap ADR §rules). `SuspendUser`/`ReinstateUser` act on a TARGET
/// user (by path id), so this adapter implements the narrow [UserAdminRepository]
/// that exposes exactly those two operations, reading/writing the SAME
/// `identity.users` row the directory owns.
///
/// The adapter is *total* (Application ADR §2): it never throws. It speaks only
/// in the domain [User] aggregate and typed ids; SQL and rows never leak. A
/// driver failure is surfaced as [ErrorKind.transient]; a malformed row is
/// mapped to a transient `identity.row_corrupt` (mirroring the directory
/// adapter's own guard). All queries bind values through `@named` parameters
/// (Security ADR §2).
///
/// The sanction is a **status-only** mutation: [updateUser] writes ONLY the
/// `status` column (plus the `updated_at` maintenance the migration also backs
/// with a trigger). It never touches `role` or `email` — the admin surface has
/// no authority over those (role elevation is a separate platform decision;
/// email is provider-sourced), so a stray field can never ride in on a
/// status change.
final class PostgresUserAdminRepository implements UserAdminRepository {
  /// Creates the repository over an open [PostgresConnection].
  const PostgresUserAdminRepository(this._connection);

  final PostgresConnection _connection;

  // --------------------------------------------------------------------------
  // findUserById — resolve a target user by id, or null
  // --------------------------------------------------------------------------

  static const String _findSql = '''
SELECT id, email, role::text, status::text
FROM identity.users
WHERE id = @id
''';

  @override
  Future<Result<User?>> findUserById(UserId id) async {
    final result = await _connection.query(
      _findSql,
      parameters: {'id': id.value},
    );
    return switch (result) {
      Err<List<Map<String, dynamic>>>(:final error) => Result.err(error),
      Ok<List<Map<String, dynamic>>>(:final value) =>
        value.isEmpty ? const Result.ok(null) : _mapOne(value.first),
    };
  }

  // --------------------------------------------------------------------------
  // updateUser — persist a status-only transition
  // --------------------------------------------------------------------------

  // Writes ONLY the status column (the sole field the admin surface mutates);
  // role/email are untouched. `updated_at = now()` keeps the column honest (the
  // migration's trigger is the backstop). RETURNING re-reads the row so the
  // stored value — not the in-memory candidate — is what the caller observes,
  // mirroring the directory adapter's upsert-returning discipline. A WHERE that
  // matches no row (the user vanished between find and update) RETURNs nothing,
  // surfaced as a transient `identity.update_no_row` rather than a silent no-op.
  static const String _updateSql = '''
UPDATE identity.users
SET status = @status,
    updated_at = now()
WHERE id = @id
RETURNING id, email, role::text, status::text
''';

  @override
  Future<Result<User>> updateUser(User user) async {
    final result = await _connection.query(
      _updateSql,
      parameters: {'id': user.id.value, 'status': _statusToken(user.status)},
    );
    return switch (result) {
      Err<List<Map<String, dynamic>>>(:final error) => Result.err(
        _reclassify(error),
      ),
      Ok<List<Map<String, dynamic>>>(:final value) =>
        value.isEmpty
            ? const Result.err(
                AppError.transient(
                  'identity.update_no_row',
                  'Status update affected no user row',
                ),
              )
            : _mapOne(value.first),
    };
  }

  // --------------------------------------------------------------------------
  // Row mapping (mirrors PostgresUserDirectory._mapSingleRow)
  // --------------------------------------------------------------------------

  Result<User> _mapOne(Map<String, dynamic> row) {
    final idResult = UserId.tryParse(row['id']?.toString());
    if (idResult is Err<UserId>) {
      return Result.err(_corrupt('id', idResult.error.message));
    }
    final roleResult = PlatformRole.tryParse(row['role']?.toString());
    if (roleResult is Err<PlatformRole>) {
      return Result.err(_corrupt('role', roleResult.error.message));
    }
    final status = _statusFrom(row['status']?.toString());
    if (status == null) {
      return Result.err(_corrupt('status', 'unknown status value'));
    }

    return Result.ok(
      User(
        id: (idResult as Ok<UserId>).value,
        email: row['email'] as String?,
        role: (roleResult as Ok<PlatformRole>).value,
        status: status,
      ),
    );
  }

  // The domain UserStatus -> the closed `identity.user_status` enum token
  // (migration 0001: 'active' | 'suspended'). Exhaustive over the closed set.
  static String _statusToken(UserStatus status) => switch (status) {
    UserStatus.active => 'active',
    UserStatus.suspended => 'suspended',
  };

  static UserStatus? _statusFrom(String? raw) {
    switch (raw) {
      case 'active':
        return UserStatus.active;
      case 'suspended':
        return UserStatus.suspended;
      default:
        return null;
    }
  }

  // A stored row that fails to map indicates data corruption or schema drift —
  // an infrastructure fault, surfaced as transient rather than blamed on the
  // caller (identical code/shape to the directory adapter's guard).
  static AppError _corrupt(String field, String detail) => AppError.transient(
    'identity.row_corrupt',
    'Stored user has invalid $field: $detail',
  );

  // A write-check violation (e.g. 23514 on the status enum domain) is a
  // storage-only integrity conflict; map it to an invariant so the use-case
  // sees a typed failure rather than a bare transient. Any other driver failure
  // (including a plain connection loss) passes through as the original
  // transient error.
  AppError _reclassify(AppError error) {
    final cause = error.cause;
    if (cause is! ServerException) {
      return error;
    }
    final code = cause.code;
    if (code == '23514') {
      return const AppError.invariant(
        'identity.status_invalid',
        'The status write violated a user integrity rule',
      );
    }
    return error;
  }
}
