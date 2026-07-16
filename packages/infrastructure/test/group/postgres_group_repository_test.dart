import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:infrastructure/src/db/postgres_connection.dart';
import 'package:infrastructure/src/group/postgres_group_repository.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

/// Hermetic unit tests for [PostgresGroupRepository].
///
/// These do NOT require a live database. They substitute a fake
/// [PostgresConnection] that records the SQL + parameters it is asked to run and
/// replies with a scripted [Result] per call, so we drive every *pure* branch
/// the adapter owns:
///   * `createGroupWithOwner` — the two writes (group row + owner membership)
///     run inside `runInTransaction`, in order, each `@named`-bound; a mid-write
///     Err short-circuits and the transaction outcome is that Err;
///   * `saveMembership` / `updateGroup` — the single write, `@named`-bound,
///     Ok on success and verbatim pass-through of a transient failure;
///   * `findGroup` / `findByInviteCode` — SQL shape + binding, row →
///     [Group] mapping (UTC createdAt), and `Ok(null)` on an empty result;
///   * `findMembership` / `listMemberships` — mapping to [GroupMembership]
///     (role wire-token, UTC joinedAt), `Ok(null)`/empty on absence, and the
///     `ORDER BY joined_at ASC` list shape;
///   * `groupSeasonStandings` — the season∩group SELECT over the reused
///     `leaderboard.season_standings` VIEW (SQL shape, `@group_id`/`@season_id`
///     binding, NO ORDER BY — the domain ranks), row → [GroupStandingEntry]
///     mapping incl. a `bigint` total arriving as [BigInt] and a zero row;
///   * verbatim pass-through of a transient query failure on every read;
///   * corrupt-row mapping (`group.row_corrupt`) for a bad id / role / total /
///     timestamp on each mapped surface.
///
/// The one branch that genuinely needs the driver — reclassifying a `postgres`
/// [ServerException] into a domain `invariant` conflict via the violated
/// constraint name (`groups_invite_code_key` → `group.invite_code_conflict`,
/// `group_memberships_group_user_uniq` → `group.already_member`, the FK names →
/// `group.not_found`/`group.user_not_found`) — is deliberately NOT exercised
/// here: the driver's `ServerException` has no public constructor, so that path
/// can only be verified honestly against real Postgres (see the DB-gated
/// integration test `postgres_group_repository_integration_test.dart`).

const _groupId = '11111111-1111-1111-1111-111111111111';
const _membershipId = '22222222-2222-2222-2222-222222222222';
const _ownerId = '33333333-3333-3333-3333-333333333333';
const _memberId = '44444444-4444-4444-4444-444444444444';
const _participantId = '55555555-5555-5555-5555-555555555555';
const _seasonId = '66666666-6666-6666-6666-666666666666';
const _inviteCode = 'ABCDEFGHJK';

/// A [PostgresConnection] test double that records the SQL + parameters of each
/// call and replies with a scripted [Result] per call (falling back to the last
/// scripted response once exhausted). It never touches a real pool, so the whole
/// test is hermetic. `runInTransaction` runs the action against this same fake,
/// so the scripted responses drive the transactional writes too (an Err returned
/// by the action propagates verbatim as the transaction outcome).
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

GroupId get _gId => (GroupId.tryParse(_groupId) as Ok<GroupId>).value;
UserId get _uOwner => (UserId.tryParse(_ownerId) as Ok<UserId>).value;
SeasonId get _sId => (SeasonId.tryParse(_seasonId) as Ok<SeasonId>).value;
InviteCode get _code =>
    (InviteCode.tryParse(_inviteCode) as Ok<InviteCode>).value;

Group _group() => Group.fromStored(
  id: _gId,
  ownerId: _uOwner,
  name: 'The Lads',
  inviteCode: _code,
  createdAt: DateTime.utc(2026, 7, 1),
);

GroupMembership _ownerMembership() =>
    (GroupMembership.owner(
              id:
                  (GroupMembershipId.tryParse(_membershipId)
                          as Ok<GroupMembershipId>)
                      .value,
              groupId: _gId,
              userId: _uOwner,
              joinedAt: DateTime.utc(2026, 7, 1),
            )
            as Ok<GroupMembership>)
        .value;

GroupMembership _memberMembership() =>
    (GroupMembership.join(
              id:
                  (GroupMembershipId.tryParse(_membershipId)
                          as Ok<GroupMembershipId>)
                      .value,
              groupId: _gId,
              userId: (UserId.tryParse(_memberId) as Ok<UserId>).value,
              joinedAt: DateTime.utc(2026, 7, 2),
            )
            as Ok<GroupMembership>)
        .value;

Map<String, dynamic> _groupRow({
  String id = _groupId,
  String ownerId = _ownerId,
  Object? name = 'The Lads',
  String invite = _inviteCode,
  Object createdAt = '2026-07-01T00:00:00.000Z',
}) => {
  'id': id,
  'owner_id': ownerId,
  'name': name,
  'invite_code': invite,
  'created_at': createdAt,
};

Map<String, dynamic> _membershipRow({
  String id = _membershipId,
  String groupId = _groupId,
  String userId = _ownerId,
  Object role = 'owner',
  Object joinedAt = '2026-07-01T00:00:00.000Z',
}) => {
  'id': id,
  'group_id': groupId,
  'user_id': userId,
  'role': role,
  'joined_at': joinedAt,
};

Map<String, dynamic> _standingRow({
  String participant = _participantId,
  String user = _memberId,
  Object totalPoints = 4,
  Object entryCount = 1,
  Object joinedAt = '2026-07-02T00:00:00.000Z',
}) => {
  'participant_id': participant,
  'user_id': user,
  'total_points': totalPoints,
  'entry_count': entryCount,
  'joined_at': joinedAt,
};

void main() {
  group('PostgresGroupRepository.createGroupWithOwner', () {
    test(
      'writes group then owner membership atomically, both @named-bound',
      () async {
        final conn = _FakeConnection([
          const Result.ok([]), // insert group
          const Result.ok([]), // insert owner membership
        ]);
        final repo = PostgresGroupRepository(conn);

        final result = await repo.createGroupWithOwner(
          _group(),
          _ownerMembership(),
        );

        expect(result, isA<Ok<void>>());
        expect(conn.sqls.length, 2);
        expect(conn.sqls[0], contains('INSERT INTO "group".groups'));
        expect(conn.sqls[1], contains('INSERT INTO "group".group_memberships'));
        // Group insert binding.
        expect(conn.parameters[0], {
          'id': _groupId,
          'owner_id': _ownerId,
          'name': 'The Lads',
          'invite_code': _inviteCode,
        });
        // Owner membership binding (role owner, UTC joined_at).
        expect(conn.parameters[1]['id'], _membershipId);
        expect(conn.parameters[1]['group_id'], _groupId);
        expect(conn.parameters[1]['user_id'], _ownerId);
        expect(conn.parameters[1]['role'], 'owner');
        expect(conn.parameters[1]['joined_at'], isA<DateTime>());
        expect((conn.parameters[1]['joined_at']! as DateTime).isUtc, isTrue);
      },
    );

    test(
      'a failed group insert short-circuits before the membership insert',
      () async {
        final conn = _FakeConnection([
          const Result.err(AppError.transient('db.query_failed', 'boom')),
          const Result.ok([]),
        ]);
        final repo = PostgresGroupRepository(conn);

        final result = await repo.createGroupWithOwner(
          _group(),
          _ownerMembership(),
        );

        expect(result, isA<Err<void>>());
        // Only the first (group) insert ran; the membership insert never fired.
        expect(conn.sqls.length, 1);
        expect(conn.sqls.single, contains('INSERT INTO "group".groups'));
      },
    );

    test('a failed membership insert makes the transaction fail', () async {
      final conn = _FakeConnection([
        const Result.ok([]),
        const Result.err(AppError.transient('db.query_failed', 'boom')),
      ]);
      final repo = PostgresGroupRepository(conn);

      final result = await repo.createGroupWithOwner(
        _group(),
        _ownerMembership(),
      );

      expect(result, isA<Err<void>>());
      expect(conn.sqls.length, 2);
    });
  });

  group('PostgresGroupRepository.saveMembership', () {
    test('binds the membership fields and returns Ok on success', () async {
      final conn = _rows(const []);
      final repo = PostgresGroupRepository(conn);

      final result = await repo.saveMembership(_memberMembership());

      expect(result, isA<Ok<void>>());
      expect(
        conn.sqls.single,
        contains('INSERT INTO "group".group_memberships'),
      );
      expect(conn.parameters.single['id'], _membershipId);
      expect(conn.parameters.single['group_id'], _groupId);
      expect(conn.parameters.single['user_id'], _memberId);
      expect(conn.parameters.single['role'], 'member');
      expect((conn.parameters.single['joined_at']! as DateTime).isUtc, isTrue);
    });

    test('passes a transient failure through verbatim', () async {
      final repo = PostgresGroupRepository(_fails());

      final result = await repo.saveMembership(_memberMembership());

      expect((result as Err<void>).error.kind, ErrorKind.transient);
    });
  });

  group('PostgresGroupRepository.updateGroup', () {
    test('binds id/name/invite_code and returns Ok', () async {
      final conn = _rows(const []);
      final repo = PostgresGroupRepository(conn);

      final result = await repo.updateGroup(_group());

      expect(result, isA<Ok<void>>());
      expect(conn.sqls.single, contains('UPDATE "group".groups'));
      expect(conn.parameters.single, {
        'id': _groupId,
        'name': 'The Lads',
        'invite_code': _inviteCode,
      });
    });

    test('passes a transient failure through verbatim', () async {
      final repo = PostgresGroupRepository(_fails());

      final result = await repo.updateGroup(_group());

      expect((result as Err<void>).error.kind, ErrorKind.transient);
    });
  });

  group('PostgresGroupRepository.findGroup', () {
    test('maps a row to a Group and binds the id', () async {
      final conn = _rows([_groupRow()]);
      final repo = PostgresGroupRepository(conn);

      final result = await repo.findGroup(_gId);

      final group = (result as Ok<Group?>).value!;
      expect(group.id, _gId);
      expect(group.ownerId, _uOwner);
      expect(group.name, 'The Lads');
      expect(group.inviteCode.value, _inviteCode);
      expect(group.createdAt.isUtc, isTrue);
      expect(conn.sqls.single, contains('FROM "group".groups'));
      expect(conn.sqls.single, contains('WHERE id = @id'));
      expect(conn.parameters.single, {'id': _groupId});
    });

    test('returns Ok(null) when the group does not exist', () async {
      final repo = PostgresGroupRepository(_rows(const []));

      final result = await repo.findGroup(_gId);

      expect((result as Ok<Group?>).value, isNull);
    });

    test('passes a transient failure through verbatim', () async {
      final repo = PostgresGroupRepository(_fails());

      final result = await repo.findGroup(_gId);

      expect((result as Err<Group?>).error.kind, ErrorKind.transient);
    });

    test('maps a corrupt owner id to a transient row_corrupt', () async {
      final repo = PostgresGroupRepository(
        _rows([_groupRow(ownerId: 'not-a-uuid')]),
      );

      final result = await repo.findGroup(_gId);

      final error = (result as Err<Group?>).error;
      expect(error.kind, ErrorKind.transient);
      expect(error.code, 'group.row_corrupt');
    });

    test('maps a non-text name to a transient row_corrupt', () async {
      final repo = PostgresGroupRepository(_rows([_groupRow(name: 42)]));

      final result = await repo.findGroup(_gId);

      expect((result as Err<Group?>).error.code, 'group.row_corrupt');
    });

    test('maps a malformed invite code to a transient row_corrupt', () async {
      final repo = PostgresGroupRepository(_rows([_groupRow(invite: 'bad')]));

      final result = await repo.findGroup(_gId);

      expect((result as Err<Group?>).error.code, 'group.row_corrupt');
    });

    test('maps an absent created_at to a transient row_corrupt', () async {
      final conn = _rows([_groupRow()..['created_at'] = 42]);
      final repo = PostgresGroupRepository(conn);

      final result = await repo.findGroup(_gId);

      expect((result as Err<Group?>).error.code, 'group.row_corrupt');
    });
  });

  group('PostgresGroupRepository.findByInviteCode', () {
    test('maps a row to a Group and binds the invite code', () async {
      final conn = _rows([_groupRow()]);
      final repo = PostgresGroupRepository(conn);

      final result = await repo.findByInviteCode(_code);

      expect((result as Ok<Group?>).value!.id, _gId);
      expect(conn.sqls.single, contains('WHERE invite_code = @invite_code'));
      expect(conn.parameters.single, {'invite_code': _inviteCode});
    });

    test(
      'returns Ok(null) when no group has that code (rotated/stale)',
      () async {
        final repo = PostgresGroupRepository(_rows(const []));

        final result = await repo.findByInviteCode(_code);

        expect((result as Ok<Group?>).value, isNull);
      },
    );
  });

  group('PostgresGroupRepository.findMembership', () {
    test(
      'maps a row to a GroupMembership and binds the composite key',
      () async {
        final conn = _rows([_membershipRow()]);
        final repo = PostgresGroupRepository(conn);

        final result = await repo.findMembership(_gId, _uOwner);

        final membership = (result as Ok<GroupMembership?>).value!;
        expect(membership.id.value, _membershipId);
        expect(membership.groupId, _gId);
        expect(membership.userId, _uOwner);
        expect(membership.role, GroupRole.owner);
        expect(membership.joinedAt.isUtc, isTrue);
        expect(
          conn.sqls.single,
          contains('WHERE group_id = @group_id AND user_id = @user_id'),
        );
        expect(conn.parameters.single, {
          'group_id': _groupId,
          'user_id': _ownerId,
        });
      },
    );

    test('returns Ok(null) when the user is not a member', () async {
      final repo = PostgresGroupRepository(_rows(const []));

      final result = await repo.findMembership(_gId, _uOwner);

      expect((result as Ok<GroupMembership?>).value, isNull);
    });

    test('maps an unknown role to a transient row_corrupt', () async {
      final repo = PostgresGroupRepository(
        _rows([_membershipRow(role: 'superuser')]),
      );

      final result = await repo.findMembership(_gId, _uOwner);

      expect((result as Err<GroupMembership?>).error.code, 'group.row_corrupt');
    });

    test('passes a transient failure through verbatim', () async {
      final repo = PostgresGroupRepository(_fails());

      final result = await repo.findMembership(_gId, _uOwner);

      expect((result as Err<GroupMembership?>).error.kind, ErrorKind.transient);
    });
  });

  group('PostgresGroupRepository.listMemberships', () {
    test('maps rows in joined_at-asc order and binds the group id', () async {
      final conn = _rows([
        _membershipRow(),
        _membershipRow(
          id: '77777777-7777-7777-7777-777777777777',
          userId: _memberId,
          role: 'member',
          joinedAt: '2026-07-02T00:00:00.000Z',
        ),
      ]);
      final repo = PostgresGroupRepository(conn);

      final result = await repo.listMemberships(_gId);

      final memberships = (result as Ok<List<GroupMembership>>).value;
      expect(memberships.length, 2);
      expect(memberships.first.role, GroupRole.owner);
      expect(memberships.last.role, GroupRole.member);
      expect(conn.sqls.single, contains('ORDER BY joined_at ASC'));
      expect(conn.parameters.single, {'group_id': _groupId});
    });

    test('an empty group yields Ok(empty)', () async {
      final repo = PostgresGroupRepository(_rows(const []));

      final result = await repo.listMemberships(_gId);

      expect((result as Ok<List<GroupMembership>>).value, isEmpty);
    });

    test('a corrupt row fails the whole list with row_corrupt', () async {
      final repo = PostgresGroupRepository(
        _rows([_membershipRow(id: 'not-a-uuid')]),
      );

      final result = await repo.listMemberships(_gId);

      expect(
        (result as Err<List<GroupMembership>>).error.code,
        'group.row_corrupt',
      );
    });

    test('passes a transient failure through verbatim', () async {
      final repo = PostgresGroupRepository(_fails());

      final result = await repo.listMemberships(_gId);

      expect(
        (result as Err<List<GroupMembership>>).error.kind,
        ErrorKind.transient,
      );
    });
  });

  group('PostgresGroupRepository.groupSeasonStandings', () {
    test(
      'maps rows to unranked entries and binds group+season, no ORDER BY',
      () async {
        final conn = _rows([
          _standingRow(totalPoints: 7, entryCount: 2),
          _standingRow(
            participant: '88888888-8888-8888-8888-888888888888',
            user: '99999999-9999-9999-9999-999999999999',
            totalPoints: 0,
            entryCount: 0,
            joinedAt: '2026-07-03T00:00:00.000Z',
          ),
        ]);
        final repo = PostgresGroupRepository(conn);

        final result = await repo.groupSeasonStandings(
          groupId: _gId,
          seasonId: _sId,
        );

        final entries = (result as Ok<List<GroupStandingEntry>>).value;
        expect(entries.length, 2);

        final first = entries.first;
        expect(first.userId, (UserId.tryParse(_memberId) as Ok<UserId>).value);
        expect(
          first.entry.participantId,
          (ParticipantId.tryParse(_participantId) as Ok<ParticipantId>).value,
        );
        expect(first.entry.totalPoints, 7);
        expect(first.entry.entryCount, 2);
        expect(first.entry.joinedAt.isUtc, isTrue);
        // Unranked: the adapter never assigns a rank (the domain does).
        expect(first.entry.isRanked, isFalse);
        expect(first.entry.rank, 0);

        // A never-credited member appears with a zero total.
        expect(entries.last.entry.totalPoints, 0);
        expect(entries.last.entry.entryCount, 0);

        // SQL shape + binding; no ORDER BY (ranking lives in the domain).
        expect(conn.sqls.single, contains('FROM leaderboard.season_standings'));
        expect(conn.sqls.single, contains('"group".group_memberships'));
        expect(conn.sqls.single, contains('WHERE s.season_id = @season_id'));
        expect(conn.sqls.single, contains('m.group_id = @group_id'));
        expect(conn.sqls.single, isNot(contains('ORDER BY')));
        expect(conn.parameters.single, {
          'group_id': _groupId,
          'season_id': _seasonId,
        });
      },
    );

    test('reads a bigint SUM/count arriving as BigInt', () async {
      final conn = _rows([
        _standingRow(totalPoints: BigInt.from(21), entryCount: BigInt.from(4)),
      ]);
      final repo = PostgresGroupRepository(conn);

      final result = await repo.groupSeasonStandings(
        groupId: _gId,
        seasonId: _sId,
      );

      final entries = (result as Ok<List<GroupStandingEntry>>).value;
      expect(entries.single.entry.totalPoints, 21);
      expect(entries.single.entry.entryCount, 4);
    });

    test('an empty group∩season board is Ok(empty)', () async {
      final repo = PostgresGroupRepository(_rows(const []));

      final result = await repo.groupSeasonStandings(
        groupId: _gId,
        seasonId: _sId,
      );

      expect((result as Ok<List<GroupStandingEntry>>).value, isEmpty);
    });

    test('passes a transient failure through verbatim', () async {
      final repo = PostgresGroupRepository(_fails());

      final result = await repo.groupSeasonStandings(
        groupId: _gId,
        seasonId: _sId,
      );

      expect(
        (result as Err<List<GroupStandingEntry>>).error.kind,
        ErrorKind.transient,
      );
    });

    test('maps a corrupt user id to a transient row_corrupt', () async {
      final repo = PostgresGroupRepository(
        _rows([_standingRow(user: 'not-a-uuid')]),
      );

      final result = await repo.groupSeasonStandings(
        groupId: _gId,
        seasonId: _sId,
      );

      expect(
        (result as Err<List<GroupStandingEntry>>).error.code,
        'group.row_corrupt',
      );
    });

    test('maps a corrupt participant id to a transient row_corrupt', () async {
      final repo = PostgresGroupRepository(
        _rows([_standingRow(participant: 'not-a-uuid')]),
      );

      final result = await repo.groupSeasonStandings(
        groupId: _gId,
        seasonId: _sId,
      );

      expect(
        (result as Err<List<GroupStandingEntry>>).error.code,
        'group.row_corrupt',
      );
    });

    test('maps a non-int total to a transient row_corrupt', () async {
      final repo = PostgresGroupRepository(
        _rows([_standingRow(totalPoints: 'nonsense')]),
      );

      final result = await repo.groupSeasonStandings(
        groupId: _gId,
        seasonId: _sId,
      );

      expect(
        (result as Err<List<GroupStandingEntry>>).error.code,
        'group.row_corrupt',
      );
    });

    test('maps an absent joined_at to a transient row_corrupt', () async {
      final conn = _rows([_standingRow()..['joined_at'] = 42]);
      final repo = PostgresGroupRepository(conn);

      final result = await repo.groupSeasonStandings(
        groupId: _gId,
        seasonId: _sId,
      );

      expect(
        (result as Err<List<GroupStandingEntry>>).error.code,
        'group.row_corrupt',
      );
    });
  });
}
