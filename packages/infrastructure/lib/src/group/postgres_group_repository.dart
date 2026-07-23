import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:infrastructure/src/db/postgres_connection.dart';
// `postgres` exports its own `Result`; we only need its exception hierarchy here
// (to read the SQLSTATE `code`/`constraintName` off a `ServerException`), so
// hide `Result` to keep `Result<T>` unambiguously our `shared` union.
import 'package:postgres/postgres.dart' hide Result;
import 'package:shared/shared.dart';

/// Postgres-backed [GroupRepository] + [GroupStandingsReader] over the
/// `group.groups` / `group.group_memberships` tables and the reused
/// `leaderboard.season_standings` VIEW (Database ADR; migration
/// `0007_group.sql`).
///
/// A Group is an orthogonal social container (Groups decision #1): this adapter
/// writes/reads only the group + membership tables, and the group leaderboard is
/// the ratified season-standings projection INTERSECTED with the group's
/// membership (decision #4 — NO new points source, NO new ranking logic; ranking
/// is the pure domain's job in the use-case).
///
/// The adapter is *total* (Application ADR §2): it never throws. It speaks only
/// in the domain [Group]/[GroupMembership] aggregates, the [GroupStandingEntry]
/// pairing, and typed ids; SQL and rows never leak. A driver failure surfaces as
/// [ErrorKind.transient]; a storage-integrity conflict it can only detect at the
/// storage layer (a unique/FK violation) is reclassified to a typed
/// [ErrorKind.invariant] by the EXPLICITLY-named constraints in `0007_group.sql`
/// (`groups_invite_code_key` → `group.invite_code_conflict`,
/// `group_memberships_group_user_uniq` → `group.already_member`,
/// `group_memberships_group_id_fkey` → `group.not_found`,
/// `group_memberships_user_id_fkey`/`groups_owner_id_fkey` →
/// `group.user_not_found`). A malformed row maps to transient
/// `group.row_corrupt`. All queries bind through `@named` parameters
/// (Security ADR §2).
///
/// **Atomicity** (decision #2): [createGroupWithOwner] writes the group row and
/// its owner membership inside a single [PostgresConnection.runInTransaction],
/// so a group can never exist without its owner row (a mid-write failure rolls
/// both back).
final class PostgresGroupRepository
    implements GroupRepository, GroupStandingsReader {
  /// Creates the repository over an open [PostgresConnection].
  const PostgresGroupRepository(this._connection);

  final PostgresConnection _connection;

  // --------------------------------------------------------------------------
  // createGroupWithOwner — atomic group + owner membership
  // --------------------------------------------------------------------------

  static const String _insertGroupSql = '''
INSERT INTO "group".groups (id, owner_id, name, invite_code)
VALUES (@id, @owner_id, @name, @invite_code)
''';

  static const String _insertMembershipSql = '''
INSERT INTO "group".group_memberships (id, group_id, user_id, role, joined_at)
VALUES (@id, @group_id, @user_id, @role, @joined_at)
''';

  @override
  Future<Result<void>> createGroupWithOwner(
    Group group,
    GroupMembership ownerMembership,
  ) {
    return _connection.runInTransaction((tx) async {
      final insertedGroup = await tx.query(
        _insertGroupSql,
        parameters: {
          'id': group.id.value,
          'owner_id': group.ownerId.value,
          'name': group.name,
          'invite_code': group.inviteCode.value,
        },
      );
      if (insertedGroup is Err<List<Map<String, dynamic>>>) {
        return Result<void>.err(_reclassify(insertedGroup.error));
      }

      final insertedMembership = await tx.query(
        _insertMembershipSql,
        parameters: {
          'id': ownerMembership.id.value,
          'group_id': ownerMembership.groupId.value,
          'user_id': ownerMembership.userId.value,
          'role': ownerMembership.role.wireValue,
          'joined_at': ownerMembership.joinedAt.toUtc(),
        },
      );
      if (insertedMembership is Err<List<Map<String, dynamic>>>) {
        return Result<void>.err(_reclassify(insertedMembership.error));
      }

      return const Result<void>.ok(null);
    });
  }

  // --------------------------------------------------------------------------
  // findGroup / findByInviteCode
  // --------------------------------------------------------------------------

  static const String _selectGroupByIdSql = '''
SELECT id, owner_id, name, invite_code, created_at
FROM "group".groups
WHERE id = @id
''';

  static const String _selectGroupByInviteSql = '''
SELECT id, owner_id, name, invite_code, created_at
FROM "group".groups
WHERE invite_code = @invite_code
''';

  @override
  Future<Result<Group?>> findGroup(GroupId id) async {
    final result = await _connection.query(
      _selectGroupByIdSql,
      parameters: {'id': id.value},
    );
    return _firstGroupOrNull(result);
  }

  @override
  Future<Result<Group?>> findByInviteCode(InviteCode inviteCode) async {
    final result = await _connection.query(
      _selectGroupByInviteSql,
      parameters: {'invite_code': inviteCode.value},
    );
    return _firstGroupOrNull(result);
  }

  Result<Group?> _firstGroupOrNull(Result<List<Map<String, dynamic>>> result) {
    return switch (result) {
      Err<List<Map<String, dynamic>>>(:final error) => Result.err(error),
      Ok<List<Map<String, dynamic>>>(:final value) =>
        value.isEmpty ? const Result.ok(null) : _mapGroup(value.first),
    };
  }

  // --------------------------------------------------------------------------
  // updateGroup — rename / invite rotation
  // --------------------------------------------------------------------------

  static const String _updateGroupSql = '''
UPDATE "group".groups
SET name = @name, invite_code = @invite_code
WHERE id = @id
''';

  @override
  Future<Result<void>> updateGroup(Group group) async {
    final result = await _connection.query(
      _updateGroupSql,
      parameters: {
        'id': group.id.value,
        'name': group.name,
        'invite_code': group.inviteCode.value,
      },
    );
    return switch (result) {
      Err<List<Map<String, dynamic>>>(:final error) => Result.err(
        _reclassify(error),
      ),
      Ok<List<Map<String, dynamic>>>() => const Result.ok(null),
    };
  }

  // --------------------------------------------------------------------------
  // saveMembership — a member joining
  // --------------------------------------------------------------------------

  @override
  Future<Result<void>> saveMembership(GroupMembership membership) async {
    final result = await _connection.query(
      _insertMembershipSql,
      parameters: {
        'id': membership.id.value,
        'group_id': membership.groupId.value,
        'user_id': membership.userId.value,
        'role': membership.role.wireValue,
        'joined_at': membership.joinedAt.toUtc(),
      },
    );
    return switch (result) {
      Err<List<Map<String, dynamic>>>(:final error) => Result.err(
        _reclassify(error),
      ),
      Ok<List<Map<String, dynamic>>>() => const Result.ok(null),
    };
  }

  // --------------------------------------------------------------------------
  // findMembership / listMemberships
  // --------------------------------------------------------------------------

  static const String _selectMembershipSql = '''
SELECT id, group_id, user_id, role::text, joined_at
FROM "group".group_memberships
WHERE group_id = @group_id AND user_id = @user_id
''';

  static const String _listMembershipsSql = '''
SELECT id, group_id, user_id, role::text, joined_at
FROM "group".group_memberships
WHERE group_id = @group_id
ORDER BY joined_at ASC, id ASC
''';

  @override
  Future<Result<GroupMembership?>> findMembership(
    GroupId groupId,
    UserId userId,
  ) async {
    final result = await _connection.query(
      _selectMembershipSql,
      parameters: {'group_id': groupId.value, 'user_id': userId.value},
    );
    return switch (result) {
      Err<List<Map<String, dynamic>>>(:final error) => Result.err(error),
      Ok<List<Map<String, dynamic>>>(:final value) =>
        value.isEmpty ? const Result.ok(null) : _mapMembership(value.first),
    };
  }

  @override
  Future<Result<List<GroupMembership>>> listMemberships(GroupId groupId) async {
    final result = await _connection.query(
      _listMembershipsSql,
      parameters: {'group_id': groupId.value},
    );
    return switch (result) {
      Err<List<Map<String, dynamic>>>(:final error) => Result.err(error),
      Ok<List<Map<String, dynamic>>>(:final value) => _mapMemberships(value),
    };
  }

  // --------------------------------------------------------------------------
  // groupSeasonStandings — the reused season projection ∩ group membership
  // --------------------------------------------------------------------------

  // Intersect the ratified season-standings projection with the group's
  // membership: a member appears ONLY IF they are also a season participant of
  // the same season (join the VIEW's participant → its user via
  // competition.participants, then require that user to be a member of the
  // group). NO ORDER BY — the pure domain SeasonLeaderboard.rank owns ordering
  // and "1224" ranks (decision #4: no new ranking logic). The VIEW already
  // scopes the SUM to the season and nets in corrections (Axiom 5).
  static const String _selectGroupSeasonStandingsSql = '''
SELECT
  s.participant_id AS participant_id,
  p.user_id        AS user_id,
  s.total_points   AS total_points,
  s.entry_count    AS entry_count,
  s.joined_at      AS joined_at
FROM leaderboard.season_standings s
JOIN competition.participants p ON p.id = s.participant_id
JOIN "group".group_memberships m ON m.user_id = p.user_id
WHERE s.season_id = @season_id
  AND m.group_id = @group_id
''';

  @override
  Future<Result<List<GroupStandingEntry>>> groupSeasonStandings({
    required GroupId groupId,
    required SeasonId seasonId,
  }) async {
    final result = await _connection.query(
      _selectGroupSeasonStandingsSql,
      parameters: {'group_id': groupId.value, 'season_id': seasonId.value},
    );
    return switch (result) {
      Err<List<Map<String, dynamic>>>(:final error) => Result.err(error),
      Ok<List<Map<String, dynamic>>>(:final value) => _mapStandings(value),
    };
  }

  // --------------------------------------------------------------------------
  // Row mapping
  // --------------------------------------------------------------------------

  Result<Group?> _mapGroup(Map<String, dynamic> row) {
    final idResult = GroupId.tryParse(row['id']?.toString());
    final ownerIdResult = UserId.tryParse(row['owner_id']?.toString());
    final name = row['name'];
    final inviteResult = InviteCode.tryParse(row['invite_code']?.toString());
    final createdAt = _readUtcTimestamp(row['created_at']);

    if (idResult is Err<GroupId>) {
      return Result.err(_corrupt('groups', 'id', idResult.error.message));
    }
    if (ownerIdResult is Err<UserId>) {
      return Result.err(
        _corrupt('groups', 'owner_id', ownerIdResult.error.message),
      );
    }
    if (name is! String) {
      return Result.err(_corrupt('groups', 'name', 'null or not text'));
    }
    if (inviteResult is Err<InviteCode>) {
      return Result.err(
        _corrupt('groups', 'invite_code', inviteResult.error.message),
      );
    }
    if (createdAt == null) {
      return Result.err(_corrupt('groups', 'created_at', 'not a timestamp'));
    }

    return Result.ok(
      Group.fromStored(
        id: (idResult as Ok<GroupId>).value,
        ownerId: (ownerIdResult as Ok<UserId>).value,
        name: name,
        inviteCode: (inviteResult as Ok<InviteCode>).value,
        createdAt: createdAt,
      ),
    );
  }

  Result<List<GroupMembership>> _mapMemberships(
    List<Map<String, dynamic>> rows,
  ) {
    final list = <GroupMembership>[];
    for (final row in rows) {
      final mapped = _mapMembership(row);
      if (mapped is Err<GroupMembership?>) {
        return Result.err(mapped.error);
      }
      final value = (mapped as Ok<GroupMembership?>).value;
      if (value == null) {
        return Result.err(_corrupt('group_memberships', 'row', 'null mapping'));
      }
      list.add(value);
    }
    return Result.ok(List<GroupMembership>.unmodifiable(list));
  }

  Result<GroupMembership?> _mapMembership(Map<String, dynamic> row) {
    final idResult = GroupMembershipId.tryParse(row['id']?.toString());
    final groupIdResult = GroupId.tryParse(row['group_id']?.toString());
    final userIdResult = UserId.tryParse(row['user_id']?.toString());
    final roleResult = GroupRole.tryParse(row['role']?.toString());
    final joinedAt = _readUtcTimestamp(row['joined_at']);

    if (idResult is Err<GroupMembershipId>) {
      return Result.err(
        _corrupt('group_memberships', 'id', idResult.error.message),
      );
    }
    if (groupIdResult is Err<GroupId>) {
      return Result.err(
        _corrupt('group_memberships', 'group_id', groupIdResult.error.message),
      );
    }
    if (userIdResult is Err<UserId>) {
      return Result.err(
        _corrupt('group_memberships', 'user_id', userIdResult.error.message),
      );
    }
    if (roleResult is Err<GroupRole>) {
      return Result.err(
        _corrupt('group_memberships', 'role', roleResult.error.message),
      );
    }
    if (joinedAt == null) {
      return Result.err(
        _corrupt('group_memberships', 'joined_at', 'not a timestamp'),
      );
    }

    return Result.ok(
      GroupMembership.fromStored(
        id: (idResult as Ok<GroupMembershipId>).value,
        groupId: (groupIdResult as Ok<GroupId>).value,
        userId: (userIdResult as Ok<UserId>).value,
        role: (roleResult as Ok<GroupRole>).value,
        joinedAt: joinedAt,
      ),
    );
  }

  Result<List<GroupStandingEntry>> _mapStandings(
    List<Map<String, dynamic>> rows,
  ) {
    final list = <GroupStandingEntry>[];
    for (final row in rows) {
      final userIdResult = UserId.tryParse(row['user_id']?.toString());
      final participantIdResult = ParticipantId.tryParse(
        row['participant_id']?.toString(),
      );
      final totalPoints = _readInt(row['total_points']);
      final entryCount = _readInt(row['entry_count']);
      final joinedAt = _readUtcTimestamp(row['joined_at']);

      if (userIdResult is Err<UserId>) {
        return Result.err(
          _corrupt('season_standings', 'user_id', userIdResult.error.message),
        );
      }
      if (participantIdResult is Err<ParticipantId>) {
        return Result.err(
          _corrupt(
            'season_standings',
            'participant_id',
            participantIdResult.error.message,
          ),
        );
      }
      if (totalPoints == null) {
        return Result.err(
          _corrupt('season_standings', 'total_points', 'not an integer'),
        );
      }
      if (entryCount == null) {
        return Result.err(
          _corrupt('season_standings', 'entry_count', 'not an integer'),
        );
      }
      if (joinedAt == null) {
        return Result.err(
          _corrupt('season_standings', 'joined_at', 'not a timestamp'),
        );
      }

      final projected = LeaderboardEntry.projected(
        participantId: (participantIdResult as Ok<ParticipantId>).value,
        totalPoints: totalPoints,
        entryCount: entryCount,
        joinedAt: joinedAt,
      );
      if (projected is Err<LeaderboardEntry>) {
        return Result.err(
          _corrupt('season_standings', 'row', projected.error.message),
        );
      }

      list.add(
        GroupStandingEntry(
          userId: (userIdResult as Ok<UserId>).value,
          entry: (projected as Ok<LeaderboardEntry>).value,
        ),
      );
    }
    return Result.ok(List<GroupStandingEntry>.unmodifiable(list));
  }

  // --------------------------------------------------------------------------
  // Shared helpers (mirror the ledger/scoring/competition/leaderboard adapters)
  // --------------------------------------------------------------------------

  AppError _reclassify(AppError error) {
    final cause = error.cause;
    if (cause is! ServerException) {
      return error;
    }
    final code = cause.code;
    // 23505 unique_violation, 23503 foreign_key_violation, 23514 check_violation.
    const integrityCodes = {'23505', '23503', '23514'};
    if (code == null || !integrityCodes.contains(code)) {
      return error;
    }
    final constraint = cause.constraintName;
    switch (constraint) {
      case 'groups_invite_code_key':
        return const AppError.invariant(
          'group.invite_code_conflict',
          'A group with that invite code already exists',
        );
      case 'group_memberships_group_user_uniq':
        return const AppError.invariant(
          'group.already_member',
          'The user is already a member of the group',
        );
      case 'group_memberships_group_id_fkey':
        return const AppError.invariant('group.not_found', 'Group not found');
      case 'group_memberships_user_id_fkey':
      case 'groups_owner_id_fkey':
        return const AppError.invariant(
          'group.user_not_found',
          'User not found',
        );
      case 'groups_name_len_chk':
        return const AppError.invariant(
          'group.integrity_violation',
          'The group name violated a length constraint',
        );
    }
    // A group id PK collision (no named constraint) or any other integrity code.
    return const AppError.invariant(
      'group.integrity_violation',
      'The write violated a group integrity rule',
    );
  }

  static int? _readInt(Object? raw) {
    if (raw is int) {
      return raw;
    }
    if (raw is BigInt && raw.isValidInt) {
      return raw.toInt();
    }
    if (raw is String) {
      return int.tryParse(raw);
    }
    return null;
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

  static AppError _corrupt(String table, String field, String detail) =>
      AppError.transient(
        'group.row_corrupt',
        'Stored $table row has invalid $field: $detail',
      );
}
