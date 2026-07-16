import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:infrastructure/src/db/postgres_connection.dart';
import 'package:shared/shared.dart';

/// Postgres-backed [UserDirectory] over the canonical `identity.users` table
/// (Database ADR, Section 3; migration `0001_identity.sql`).
///
/// "Ensure" semantics are implemented as a single idempotent upsert
/// (`INSERT ... ON CONFLICT`): first sight of a verified principal creates the
/// canonical row seeded with the token role and `active` status; subsequent
/// calls reconcile the provider-sourced email while leaving the platform-owned
/// `role` and `status` untouched (those are administered by the platform, not
/// re-derived from a token). The upsert `RETURNING`s the current row so the
/// authoritative stored values — not the token's — are what the caller sees.
final class PostgresUserDirectory implements UserDirectory {
  /// Creates the directory over an open [PostgresConnection].
  const PostgresUserDirectory(this._connection);

  final PostgresConnection _connection;

  static const String _upsertSql = '''
INSERT INTO identity.users (id, email, role, status)
VALUES (@id, @email, @role, 'active')
ON CONFLICT (id) DO UPDATE
  SET email = EXCLUDED.email,
      updated_at = now()
RETURNING id, email, role, status
''';

  @override
  Future<Result<User>> ensureUser(AuthenticatedUser principal) async {
    final queryResult = await _connection.query(
      _upsertSql,
      parameters: {
        'id': principal.userId.value,
        'email': principal.email,
        // Seed role from the verified principal on first insert only; on
        // conflict the stored role is preserved (not in the UPDATE SET clause).
        'role': principal.role.name,
      },
    );

    return switch (queryResult) {
      Ok<List<Map<String, dynamic>>>(:final value) => _mapSingleRow(value),
      Err<List<Map<String, dynamic>>>(:final error) => Result.err(error),
    };
  }

  /// Maps the single upsert-returned row to a domain [User], guarding against a
  /// (should-be-impossible) empty result or malformed stored data.
  Result<User> _mapSingleRow(List<Map<String, dynamic>> rows) {
    if (rows.isEmpty) {
      return const Result.err(
        AppError.transient(
          'identity.upsert_no_row',
          'User upsert returned no row',
        ),
      );
    }
    final row = rows.first;

    final idResult = UserId.tryParse(row['id']?.toString());
    final roleResult = PlatformRole.tryParse(row['role']?.toString());
    final status = _statusFrom(row['status']?.toString());

    if (idResult is Err<UserId>) {
      return Result.err(_corrupt('id', idResult.error.message));
    }
    if (roleResult is Err<PlatformRole>) {
      return Result.err(_corrupt('role', roleResult.error.message));
    }
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

  /// A stored row that fails to map indicates data corruption or a schema drift
  /// — an infrastructure fault, surfaced as transient rather than blamed on the
  /// caller.
  static AppError _corrupt(String field, String detail) => AppError.transient(
    'identity.row_corrupt',
    'Stored user has invalid $field: $detail',
  );
}
