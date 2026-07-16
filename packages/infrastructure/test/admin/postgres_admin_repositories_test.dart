import 'package:domain/domain.dart';
import 'package:infrastructure/src/admin/postgres_audit_log_repository.dart';
import 'package:infrastructure/src/admin/postgres_user_admin_repository.dart';
import 'package:infrastructure/src/db/postgres_connection.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

/// Hermetic unit tests for the Admin infrastructure adapters
/// ([PostgresUserAdminRepository] + [PostgresAuditLogRepository]).
///
/// These do NOT require a live database. They substitute a fake
/// [PostgresConnection] that records the SQL + parameters it is asked to run and
/// replies with a scripted [Result] per call, so we drive every *pure* branch
/// the adapters own:
///   * `PostgresUserAdminRepository.findUserById` — SELECT shape + `@id`
///     binding, row → [User] mapping, `Ok(null)` on an empty result, transient
///     pass-through, and the four `identity.row_corrupt` branches (bad id /
///     role / status);
///   * `PostgresUserAdminRepository.updateUser` — the status-only UPDATE …
///     RETURNING shape (ONLY `status` + `updated_at` bound — never role/email),
///     row → [User] mapping, `identity.update_no_row` on an empty RETURNING,
///     transient pass-through;
///   * `PostgresAuditLogRepository.append` — the plain INSERT … RETURNING id
///     shape, `@named` binding (action as its wire token, reason nullable,
///     occurred_at coerced to UTC), `Ok(entry)` on a returned row,
///     `admin.audit_append_no_row` on an empty RETURNING, transient
///     pass-through;
///   * `PostgresAuditLogRepository.list` — the `ORDER BY occurred_at DESC,
///     id DESC LIMIT @limit` shape, `@limit` binding, row → [AuditEntry]
///     mapping (nullable reason present/absent), empty-legit, corrupt-row fails
///     the list, transient pass-through.
///
/// The one branch that genuinely needs the driver — reclassifying a `postgres`
/// [ServerException] into a domain `invariant` via the violated constraint name
/// (`identity` 23514 → `identity.status_invalid`; `audit_log_pkey` →
/// `admin.audit_duplicate`; `audit_log_actor_id_fkey` →
/// `admin.audit_actor_not_found`) — is deliberately NOT exercised here: the
/// driver's `ServerException` has no public constructor, so that path can only
/// be verified honestly against real Postgres (see the DB-gated
/// `postgres_admin_repositories_integration_test.dart`).

const _userId = '11111111-1111-4111-8111-111111111111';
const _actorId = '22222222-2222-4222-8222-222222222222';
const _auditId = '33333333-3333-4333-8333-333333333333';
const _auditId2 = '44444444-4444-4444-8444-444444444444';

/// A [PostgresConnection] test double that records the SQL + parameters of each
/// call and replies with a scripted [Result] per call (falling back to the last
/// scripted response once exhausted). It never touches a real pool.
final class _FakeConnection implements PostgresConnection {
  _FakeConnection(this._responses);

  final List<Result<List<Map<String, dynamic>>>> _responses;
  int _index = 0;

  final List<String> sqls = [];
  final List<Map<String, Object?>> parameters = [];

  @override
  Future<Result<List<Map<String, dynamic>>>> query(
    String sql, {
    Map<String, Object?> parameters = const {},
  }) async {
    sqls.add(sql);
    this.parameters.add(parameters);
    final response =
        _responses[_index < _responses.length ? _index : _responses.length - 1];
    _index++;
    return response;
  }

  @override
  Future<Result<bool>> ping() async => const Result.ok(true);

  @override
  Future<Result<T>> runInTransaction<T>(
    Future<Result<T>> Function(DbExecutor tx) action,
  ) => action(this);

  @override
  Future<void> close() async {}
}

_FakeConnection _rows(List<Map<String, dynamic>> rows) =>
    _FakeConnection([Result.ok(rows)]);

_FakeConnection _fails() => _FakeConnection([
  const Result.err(
    AppError.transient('db.query_failed', 'Database query failed'),
  ),
]);

UserId get _uId => (UserId.tryParse(_userId) as Ok<UserId>).value;

Map<String, dynamic> _userRow({
  Object id = _userId,
  Object? email = 'human@example.com',
  Object role = 'user',
  Object status = 'active',
}) => {'id': id, 'email': email, 'role': role, 'status': status};

AuditEntry _auditEntry({
  String id = _auditId,
  AuditAction action = AuditAction.userSuspended,
  String targetRef = _userId,
  String? reason = 'abuse',
  DateTime? occurredAt,
}) {
  final built = AuditEntry.create(
    id: (AuditEntryId.tryParse(id) as Ok<AuditEntryId>).value,
    actorId: (UserId.tryParse(_actorId) as Ok<UserId>).value,
    action: action,
    targetRef: targetRef,
    occurredAt: occurredAt ?? DateTime.utc(2026, 7, 13, 12),
    reason: reason,
  );
  return (built as Ok<AuditEntry>).value;
}

Map<String, dynamic> _auditRow({
  Object id = _auditId,
  Object actorId = _actorId,
  Object action = 'user_suspended',
  Object targetRef = _userId,
  Object? reason = 'abuse',
  Object occurredAt = '2026-07-13T12:00:00.000Z',
}) => {
  'id': id,
  'actor_id': actorId,
  'action': action,
  'target_ref': targetRef,
  'reason': reason,
  'occurred_at': occurredAt,
};

void main() {
  group('PostgresUserAdminRepository.findUserById', () {
    test(
      'SELECTs from identity.users with @id and maps a single row',
      () async {
        final conn = _rows([_userRow(status: 'suspended')]);
        final repo = PostgresUserAdminRepository(conn);

        final result = await repo.findUserById(_uId);

        expect(conn.sqls.single, contains('FROM identity.users'));
        expect(conn.sqls.single, contains('WHERE id = @id'));
        expect(conn.parameters.single, {'id': _userId});
        final user = (result as Ok<User?>).value!;
        expect(user.id.value, _userId);
        expect(user.status, UserStatus.suspended);
        expect(user.role, PlatformRole.user);
      },
    );

    test('returns Ok(null) on an empty result (no oracle)', () async {
      final repo = PostgresUserAdminRepository(_rows([]));
      final result = await repo.findUserById(_uId);
      expect((result as Ok<User?>).value, isNull);
    });

    test('passes a transient query failure through verbatim', () async {
      final repo = PostgresUserAdminRepository(_fails());
      final result = await repo.findUserById(_uId);
      expect((result as Err<User?>).error.kind, ErrorKind.transient);
    });

    test('maps a bad id to identity.row_corrupt', () async {
      final repo = PostgresUserAdminRepository(_rows([_userRow(id: 'nope')]));
      final result = await repo.findUserById(_uId);
      final error = (result as Err<User?>).error;
      expect(error.code, 'identity.row_corrupt');
      expect(error.kind, ErrorKind.transient);
    });

    test('maps an unknown role to identity.row_corrupt', () async {
      final repo = PostgresUserAdminRepository(
        _rows([_userRow(role: 'wizard')]),
      );
      final result = await repo.findUserById(_uId);
      expect((result as Err<User?>).error.code, 'identity.row_corrupt');
    });

    test('maps an unknown status to identity.row_corrupt', () async {
      final repo = PostgresUserAdminRepository(
        _rows([_userRow(status: 'banished')]),
      );
      final result = await repo.findUserById(_uId);
      expect((result as Err<User?>).error.code, 'identity.row_corrupt');
    });
  });

  group('PostgresUserAdminRepository.updateUser', () {
    User _candidate({UserStatus status = UserStatus.suspended}) => User(
      id: _uId,
      email: 'human@example.com',
      role: PlatformRole.user,
      status: status,
    );

    test(
      'UPDATEs ONLY status (+updated_at) and RETURNs the stored row',
      () async {
        final conn = _rows([_userRow(status: 'suspended')]);
        final repo = PostgresUserAdminRepository(conn);

        final result = await repo.updateUser(_candidate());

        final sql = conn.sqls.single;
        expect(sql, contains('UPDATE identity.users'));
        expect(sql, contains('SET status = @status'));
        expect(sql, contains('updated_at = now()'));
        expect(sql, contains('RETURNING'));
        // Bind carries ONLY id + status — never role/email.
        expect(conn.parameters.single, {'id': _userId, 'status': 'suspended'});
        expect((result as Ok<User>).value.status, UserStatus.suspended);
      },
    );

    test(
      'an empty RETURNING is identity.update_no_row (not a silent no-op)',
      () async {
        final repo = PostgresUserAdminRepository(_rows([]));
        final result = await repo.updateUser(_candidate());
        final error = (result as Err<User>).error;
        expect(error.code, 'identity.update_no_row');
        expect(error.kind, ErrorKind.transient);
      },
    );

    test('binds the active token when reinstating', () async {
      final conn = _rows([_userRow(status: 'active')]);
      final repo = PostgresUserAdminRepository(conn);
      await repo.updateUser(_candidate(status: UserStatus.active));
      expect(conn.parameters.single['status'], 'active');
    });

    test('passes a transient update failure through', () async {
      final repo = PostgresUserAdminRepository(_fails());
      final result = await repo.updateUser(_candidate());
      expect((result as Err<User>).error.kind, ErrorKind.transient);
    });
  });

  group('PostgresAuditLogRepository.append', () {
    test('INSERTs one row with @named binding and echoes the entry', () async {
      final conn = _rows([
        {'id': _auditId},
      ]);
      final repo = PostgresAuditLogRepository(conn);

      final result = await repo.append(_auditEntry());

      final sql = conn.sqls.single;
      expect(sql, contains('INSERT INTO admin.audit_log'));
      expect(sql, contains('RETURNING id'));
      final params = conn.parameters.single;
      expect(params['id'], _auditId);
      expect(params['actor_id'], _actorId);
      // action bound as its stable wire token, never a Dart enum name.
      expect(params['action'], 'user_suspended');
      expect(params['target_ref'], _userId);
      expect(params['reason'], 'abuse');
      expect(params['occurred_at'], isA<DateTime>());
      expect((params['occurred_at']! as DateTime).isUtc, isTrue);
      expect((result as Ok<AuditEntry>).value.id.value, _auditId);
    });

    test('binds a null reason for an action that carries none', () async {
      final conn = _rows([
        {'id': _auditId},
      ]);
      final repo = PostgresAuditLogRepository(conn);
      await repo.append(
        _auditEntry(action: AuditAction.participantLedgerViewed, reason: null),
      );
      expect(conn.parameters.single['reason'], isNull);
      expect(conn.parameters.single['action'], 'participant_ledger_viewed');
    });

    test('an empty RETURNING is admin.audit_append_no_row', () async {
      final repo = PostgresAuditLogRepository(_rows([]));
      final result = await repo.append(_auditEntry());
      final error = (result as Err<AuditEntry>).error;
      expect(error.code, 'admin.audit_append_no_row');
      expect(error.kind, ErrorKind.transient);
    });

    test('passes a transient append failure through', () async {
      final repo = PostgresAuditLogRepository(_fails());
      final result = await repo.append(_auditEntry());
      expect((result as Err<AuditEntry>).error.kind, ErrorKind.transient);
    });
  });

  group('PostgresAuditLogRepository.list', () {
    test(
      'SELECTs newest-first (occurred_at DESC, id DESC) capped at @limit',
      () async {
        final conn = _rows([
          _auditRow(id: _auditId2, action: 'user_reinstated', reason: 'appeal'),
          _auditRow(id: _auditId),
        ]);
        final repo = PostgresAuditLogRepository(conn);

        final result = await repo.list(limit: 25);

        final sql = conn.sqls.single;
        expect(sql, contains('FROM admin.audit_log'));
        expect(sql, contains('ORDER BY occurred_at DESC, id DESC'));
        expect(sql, contains('LIMIT @limit'));
        expect(conn.parameters.single, {'limit': 25});
        final rows = (result as Ok<List<AuditEntry>>).value;
        expect(rows, hasLength(2));
        expect(rows.first.id.value, _auditId2);
        expect(rows.first.action, AuditAction.userReinstated);
      },
    );

    test('maps a row with a NULL reason (reason omitted → null)', () async {
      final repo = PostgresAuditLogRepository(_rows([_auditRow(reason: null)]));
      final result = await repo.list(limit: 10);
      final rows = (result as Ok<List<AuditEntry>>).value;
      expect(rows.single.reason, isNull);
    });

    test('an empty trail is Ok(empty), never an error', () async {
      final repo = PostgresAuditLogRepository(_rows([]));
      final result = await repo.list(limit: 10);
      expect((result as Ok<List<AuditEntry>>).value, isEmpty);
    });

    test('a corrupt action token fails the whole list (row_corrupt)', () async {
      final repo = PostgresAuditLogRepository(
        _rows([_auditRow(action: 'nonsense')]),
      );
      final result = await repo.list(limit: 10);
      final error = (result as Err<List<AuditEntry>>).error;
      expect(error.code, 'admin.audit_row_corrupt');
      expect(error.kind, ErrorKind.transient);
    });

    test('a missing target_ref fails the list (row_corrupt)', () async {
      final repo = PostgresAuditLogRepository(
        _rows([_auditRow(targetRef: '')]),
      );
      final result = await repo.list(limit: 10);
      expect(
        (result as Err<List<AuditEntry>>).error.code,
        'admin.audit_row_corrupt',
      );
    });

    test('a non-timestamp occurred_at fails the list (row_corrupt)', () async {
      final repo = PostgresAuditLogRepository(
        _rows([_auditRow(occurredAt: 12345)]),
      );
      final result = await repo.list(limit: 10);
      expect(
        (result as Err<List<AuditEntry>>).error.code,
        'admin.audit_row_corrupt',
      );
    });

    test('passes a transient list failure through', () async {
      final repo = PostgresAuditLogRepository(_fails());
      final result = await repo.list(limit: 10);
      expect((result as Err<List<AuditEntry>>).error.kind, ErrorKind.transient);
    });
  });
}
