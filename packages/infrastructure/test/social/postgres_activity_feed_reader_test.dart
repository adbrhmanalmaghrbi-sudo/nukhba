import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:infrastructure/src/db/postgres_connection.dart';
import 'package:infrastructure/src/social/postgres_activity_feed_reader.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

/// Hermetic unit tests for [PostgresActivityFeedReader].
///
/// These do NOT require a live database. They substitute a fake
/// [PostgresConnection] that records the SQL + parameters and replies with a
/// scripted [Result], so we drive every *pure* branch the reader owns:
///   * `groupActivityFeed` — the single UNION read shape (member_joined branch
///     over `"group".group_memberships`, round_scored branch over
///     `competition.rounds` gated by an `EXISTS` on `competition.participants ∩
///     "group".group_memberships`), `@group_id`/`@limit` binding, and the
///     `ORDER BY occurred_at DESC … LIMIT @limit` cap;
///   * row → [ActivityEvent] mapping per discriminated `kind` (member_joined →
///     userId set / round_scored → roundId set), UTC occurredAt, group scoping;
///   * an empty feed is Ok(empty) (a fresh group);
///   * verbatim pass-through of a transient query failure;
///   * corrupt-row mapping (`social.row_corrupt`) for an absent occurred_at, a
///     bad user_id / round_id, and an unknown `kind` discriminator.
///
/// The feed is a pure read projection with NO table (Social decision #2), so
/// there is no write path and no `ServerException` reclassify branch to defer;
/// the DB-gated integration test documents the live-DB assembly semantics the
/// fake connection cannot execute (real UNION + EXISTS over the schema).

const _groupId = '22222222-2222-2222-2222-222222222222';
const _roundId = '33333333-3333-3333-3333-333333333333';
const _userId = '44444444-4444-4444-4444-444444444444';

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

Map<String, dynamic> _memberJoinedRow({
  String userId = _userId,
  Object occurredAt = '2026-07-12T10:00:00.000Z',
}) => {
  'kind': 'member_joined',
  'round_id': null,
  'user_id': userId,
  'occurred_at': occurredAt,
};

Map<String, dynamic> _roundScoredRow({
  String roundId = _roundId,
  Object occurredAt = '2026-07-12T09:00:00.000Z',
}) => {
  'kind': 'round_scored',
  'round_id': roundId,
  'user_id': null,
  'occurred_at': occurredAt,
};

void main() {
  group('PostgresActivityFeedReader.groupActivityFeed', () {
    test(
      'runs the UNION feed read, binds @group_id/@limit, caps the result',
      () async {
        final conn = _rows([_memberJoinedRow(), _roundScoredRow()]);
        final reader = PostgresActivityFeedReader(conn);

        final result = await reader.groupActivityFeed(groupId: _gId, limit: 50);

        expect(result, isA<Ok<List<ActivityEvent>>>());
        final sql = conn.sqls.single;
        // The member_joined branch reads group memberships for the group.
        expect(sql, contains('"group".group_memberships'));
        expect(sql, contains("'member_joined'"));
        // The round_scored branch reads scored rounds gated by an EXISTS over
        // participants ∩ group memberships.
        expect(sql, contains('competition.rounds'));
        expect(sql, contains("r.status = 'scored'"));
        expect(sql, contains('competition.participants'));
        expect(sql, contains('UNION ALL'));
        expect(sql, contains("'round_scored'"));
        // Newest-first + capped.
        expect(sql, contains('ORDER BY occurred_at DESC'));
        expect(sql, contains('LIMIT @limit'));
        expect(conn.parameters.single, {'group_id': _groupId, 'limit': 50});
      },
    );

    test(
      'maps a member_joined row (userId set, round null), UTC occurredAt',
      () async {
        final reader = PostgresActivityFeedReader(_rows([_memberJoinedRow()]));

        final result = await reader.groupActivityFeed(groupId: _gId, limit: 50);

        final event = (result as Ok<List<ActivityEvent>>).value.single;
        expect(event.type, ActivityEventType.memberJoined);
        expect(event.groupId, _gId);
        expect(event.userId, (UserId.tryParse(_userId) as Ok<UserId>).value);
        expect(event.roundId, isNull);
        expect(event.oldRank, isNull);
        expect(event.newRank, isNull);
        expect(event.occurredAt.isUtc, isTrue);
      },
    );

    test('maps a round_scored row (roundId set, user null)', () async {
      final reader = PostgresActivityFeedReader(_rows([_roundScoredRow()]));

      final result = await reader.groupActivityFeed(groupId: _gId, limit: 50);

      final event = (result as Ok<List<ActivityEvent>>).value.single;
      expect(event.type, ActivityEventType.roundScored);
      expect(event.groupId, _gId);
      expect(event.roundId, (RoundId.tryParse(_roundId) as Ok<RoundId>).value);
      expect(event.userId, isNull);
      expect(event.occurredAt.isUtc, isTrue);
    });

    test('a fresh group yields Ok(empty)', () async {
      final reader = PostgresActivityFeedReader(_rows(const []));

      final result = await reader.groupActivityFeed(groupId: _gId, limit: 50);

      expect((result as Ok<List<ActivityEvent>>).value, isEmpty);
    });

    test('passes a transient failure through verbatim', () async {
      final reader = PostgresActivityFeedReader(_fails());

      final result = await reader.groupActivityFeed(groupId: _gId, limit: 50);

      expect(
        (result as Err<List<ActivityEvent>>).error.kind,
        ErrorKind.transient,
      );
    });

    test('maps an absent occurred_at to a transient row_corrupt', () async {
      final reader = PostgresActivityFeedReader(
        _rows([_memberJoinedRow()..['occurred_at'] = 42]),
      );

      final result = await reader.groupActivityFeed(groupId: _gId, limit: 50);

      final error = (result as Err<List<ActivityEvent>>).error;
      expect(error.kind, ErrorKind.transient);
      expect(error.code, 'social.row_corrupt');
    });

    test('maps a corrupt user_id (member_joined) to a row_corrupt', () async {
      final reader = PostgresActivityFeedReader(
        _rows([_memberJoinedRow(userId: 'not-a-uuid')]),
      );

      final result = await reader.groupActivityFeed(groupId: _gId, limit: 50);

      expect(
        (result as Err<List<ActivityEvent>>).error.code,
        'social.row_corrupt',
      );
    });

    test('maps a corrupt round_id (round_scored) to a row_corrupt', () async {
      final reader = PostgresActivityFeedReader(
        _rows([_roundScoredRow(roundId: 'not-a-uuid')]),
      );

      final result = await reader.groupActivityFeed(groupId: _gId, limit: 50);

      expect(
        (result as Err<List<ActivityEvent>>).error.code,
        'social.row_corrupt',
      );
    });

    test('maps an unknown kind discriminator to a row_corrupt', () async {
      final reader = PostgresActivityFeedReader(
        _rows([
          {
            'kind': 'rank_shift',
            'round_id': null,
            'user_id': _userId,
            'occurred_at': '2026-07-12T10:00:00.000Z',
          },
        ]),
      );

      final result = await reader.groupActivityFeed(groupId: _gId, limit: 50);

      // rank_shift is not produced by this reader (no stored rank history), so
      // an unexpected discriminator is treated as a corrupt row rather than
      // silently fabricated.
      expect(
        (result as Err<List<ActivityEvent>>).error.code,
        'social.row_corrupt',
      );
    });
  });
}
