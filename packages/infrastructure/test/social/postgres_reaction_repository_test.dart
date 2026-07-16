import 'package:domain/domain.dart';
import 'package:infrastructure/src/db/postgres_connection.dart';
import 'package:infrastructure/src/social/postgres_reaction_repository.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

/// Hermetic unit tests for [PostgresReactionRepository].
///
/// These do NOT require a live database. They substitute a fake
/// [PostgresConnection] that records the SQL + parameters it is asked to run and
/// replies with a scripted [Result] per call, so we drive every *pure* branch
/// the adapter owns:
///   * `upsertReaction` — the idempotent `INSERT … ON CONFLICT ON CONSTRAINT
///     reactions_group_round_user_uniq DO UPDATE`, `@named`-bound (emoji as its
///     wire token, reacted_at coerced to a UTC [DateTime]), Ok on success and
///     verbatim pass-through of a transient failure;
///   * `findReaction` — SQL shape + `(group,round,user)` binding, row →
///     [Reaction] mapping (UTC reactedAt, emoji wire-token parse), and
///     `Ok(null)` on an empty result;
///   * `listReactionsForRound` — the `ORDER BY reacted_at ASC, id ASC` list
///     shape, `(group,round)` binding, row → [Reaction] mapping, empty on
///     absence;
///   * `removeReaction` — the `DELETE … RETURNING id` shape, `Ok(true)` when a
///     row came back and `Ok(false)` when none did (idempotent), binding;
///   * verbatim pass-through of a transient query failure on every method;
///   * corrupt-row mapping (`social.row_corrupt`) for a bad id / group_id /
///     round_id / user_id / emoji / reacted_at on each mapped surface.
///
/// The one branch that genuinely needs the driver — reclassifying a `postgres`
/// [ServerException] into a domain `invariant` conflict via the violated
/// constraint name (`reactions_group_round_user_uniq` →
/// `social.reaction_conflict`, the FK names → `social.group_not_found` /
/// `social.round_not_found` / `social.user_not_found`) — is deliberately NOT
/// exercised here: the driver's `ServerException` has no public constructor, so
/// that path can only be verified honestly against real Postgres (see the
/// DB-gated integration test `postgres_reaction_repository_integration_test.dart`).

const _reactionId = '11111111-1111-1111-1111-111111111111';
const _groupId = '22222222-2222-2222-2222-222222222222';
const _roundId = '33333333-3333-3333-3333-333333333333';
const _userId = '44444444-4444-4444-4444-444444444444';

/// A [PostgresConnection] test double that records the SQL + parameters of each
/// call and replies with a scripted [Result] per call (falling back to the last
/// scripted response once exhausted). It never touches a real pool, so the whole
/// test is hermetic.
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
RoundId get _rId => (RoundId.tryParse(_roundId) as Ok<RoundId>).value;
UserId get _uId => (UserId.tryParse(_userId) as Ok<UserId>).value;

Reaction _reaction({
  ReactionKind emoji = ReactionKind.fire,
  DateTime? reactedAt,
}) => Reaction.fromStored(
  id: (ReactionId.tryParse(_reactionId) as Ok<ReactionId>).value,
  groupId: _gId,
  roundId: _rId,
  userId: _uId,
  emoji: ReactionEmoji.of(emoji),
  reactedAt: reactedAt ?? DateTime.utc(2026, 7, 12, 9, 30),
);

Map<String, dynamic> _reactionRow({
  String id = _reactionId,
  String groupId = _groupId,
  String roundId = _roundId,
  String userId = _userId,
  Object emoji = 'fire',
  Object reactedAt = '2026-07-12T09:30:00.000Z',
}) => {
  'id': id,
  'group_id': groupId,
  'round_id': roundId,
  'user_id': userId,
  'emoji': emoji,
  'reacted_at': reactedAt,
};

void main() {
  group('PostgresReactionRepository.upsertReaction', () {
    test(
      'runs an ON CONFLICT upsert, @named-bound with the wire token + UTC',
      () async {
        final conn = _rows(const []);
        final repo = PostgresReactionRepository(conn);

        final result = await repo.upsertReaction(_reaction());

        expect(result, isA<Ok<void>>());
        expect(conn.sqls.single, contains('INSERT INTO social.reactions'));
        expect(
          conn.sqls.single,
          contains('ON CONFLICT ON CONSTRAINT reactions_group_round_user_uniq'),
        );
        expect(conn.sqls.single, contains('DO UPDATE SET'));
        expect(conn.parameters.single['id'], _reactionId);
        expect(conn.parameters.single['group_id'], _groupId);
        expect(conn.parameters.single['round_id'], _roundId);
        expect(conn.parameters.single['user_id'], _userId);
        // Emoji is bound as its stable wire token, never the presentation glyph.
        expect(conn.parameters.single['emoji'], 'fire');
        expect(conn.parameters.single['reacted_at'], isA<DateTime>());
        expect(
          (conn.parameters.single['reacted_at']! as DateTime).isUtc,
          isTrue,
        );
      },
    );

    test('binds a changed emoji as its wire token (swap-in-place)', () async {
      final conn = _rows(const []);
      final repo = PostgresReactionRepository(conn);

      await repo.upsertReaction(_reaction(emoji: ReactionKind.clap));

      expect(conn.parameters.single['emoji'], 'clap');
      // Same id — a swap is an update on the existing row, never a second row.
      expect(conn.parameters.single['id'], _reactionId);
    });

    test('passes a transient failure through verbatim', () async {
      final repo = PostgresReactionRepository(_fails());

      final result = await repo.upsertReaction(_reaction());

      expect((result as Err<void>).error.kind, ErrorKind.transient);
    });
  });

  group('PostgresReactionRepository.findReaction', () {
    test(
      'maps a row to a Reaction and binds the (group,round,user) key',
      () async {
        final conn = _rows([_reactionRow()]);
        final repo = PostgresReactionRepository(conn);

        final result = await repo.findReaction(_gId, _rId, _uId);

        final reaction = (result as Ok<Reaction?>).value!;
        expect(reaction.id.value, _reactionId);
        expect(reaction.groupId, _gId);
        expect(reaction.roundId, _rId);
        expect(reaction.userId, _uId);
        expect(reaction.emoji.kind, ReactionKind.fire);
        expect(reaction.reactedAt.isUtc, isTrue);
        expect(conn.sqls.single, contains('FROM social.reactions'));
        expect(
          conn.sqls.single,
          contains(
            'WHERE group_id = @group_id AND round_id = @round_id '
            'AND user_id = @user_id',
          ),
        );
        expect(conn.parameters.single, {
          'group_id': _groupId,
          'round_id': _roundId,
          'user_id': _userId,
        });
      },
    );

    test('returns Ok(null) when the member has not reacted', () async {
      final repo = PostgresReactionRepository(_rows(const []));

      final result = await repo.findReaction(_gId, _rId, _uId);

      expect((result as Ok<Reaction?>).value, isNull);
    });

    test('passes a transient failure through verbatim', () async {
      final repo = PostgresReactionRepository(_fails());

      final result = await repo.findReaction(_gId, _rId, _uId);

      expect((result as Err<Reaction?>).error.kind, ErrorKind.transient);
    });

    test('maps a corrupt id to a transient row_corrupt', () async {
      final repo = PostgresReactionRepository(
        _rows([_reactionRow(id: 'not-a-uuid')]),
      );

      final result = await repo.findReaction(_gId, _rId, _uId);

      final error = (result as Err<Reaction?>).error;
      expect(error.kind, ErrorKind.transient);
      expect(error.code, 'social.row_corrupt');
    });

    test('maps a corrupt group id to a transient row_corrupt', () async {
      final repo = PostgresReactionRepository(
        _rows([_reactionRow(groupId: 'not-a-uuid')]),
      );

      final result = await repo.findReaction(_gId, _rId, _uId);

      expect((result as Err<Reaction?>).error.code, 'social.row_corrupt');
    });

    test('maps a corrupt round id to a transient row_corrupt', () async {
      final repo = PostgresReactionRepository(
        _rows([_reactionRow(roundId: 'not-a-uuid')]),
      );

      final result = await repo.findReaction(_gId, _rId, _uId);

      expect((result as Err<Reaction?>).error.code, 'social.row_corrupt');
    });

    test('maps a corrupt user id to a transient row_corrupt', () async {
      final repo = PostgresReactionRepository(
        _rows([_reactionRow(userId: 'not-a-uuid')]),
      );

      final result = await repo.findReaction(_gId, _rId, _uId);

      expect((result as Err<Reaction?>).error.code, 'social.row_corrupt');
    });

    test('maps an unknown emoji token to a transient row_corrupt', () async {
      final repo = PostgresReactionRepository(
        _rows([_reactionRow(emoji: 'not-an-emoji')]),
      );

      final result = await repo.findReaction(_gId, _rId, _uId);

      expect((result as Err<Reaction?>).error.code, 'social.row_corrupt');
    });

    test('maps an absent reacted_at to a transient row_corrupt', () async {
      final conn = _rows([_reactionRow()..['reacted_at'] = 42]);
      final repo = PostgresReactionRepository(conn);

      final result = await repo.findReaction(_gId, _rId, _uId);

      expect((result as Err<Reaction?>).error.code, 'social.row_corrupt');
    });
  });

  group('PostgresReactionRepository.listReactionsForRound', () {
    test('maps rows in reacted_at-asc order and binds (group,round)', () async {
      final conn = _rows([
        _reactionRow(),
        _reactionRow(
          id: '55555555-5555-5555-5555-555555555555',
          userId: '66666666-6666-6666-6666-666666666666',
          emoji: 'laugh',
          reactedAt: '2026-07-12T10:00:00.000Z',
        ),
      ]);
      final repo = PostgresReactionRepository(conn);

      final result = await repo.listReactionsForRound(_gId, _rId);

      final reactions = (result as Ok<List<Reaction>>).value;
      expect(reactions.length, 2);
      expect(reactions.first.emoji.kind, ReactionKind.fire);
      expect(reactions.last.emoji.kind, ReactionKind.laugh);
      expect(conn.sqls.single, contains('ORDER BY reacted_at ASC, id ASC'));
      expect(
        conn.sqls.single,
        contains('WHERE group_id = @group_id AND round_id = @round_id'),
      );
      expect(conn.parameters.single, {
        'group_id': _groupId,
        'round_id': _roundId,
      });
    });

    test('a round with no reactions yields Ok(empty)', () async {
      final repo = PostgresReactionRepository(_rows(const []));

      final result = await repo.listReactionsForRound(_gId, _rId);

      expect((result as Ok<List<Reaction>>).value, isEmpty);
    });

    test('a corrupt row fails the whole list with row_corrupt', () async {
      final repo = PostgresReactionRepository(
        _rows([_reactionRow(emoji: 'not-an-emoji')]),
      );

      final result = await repo.listReactionsForRound(_gId, _rId);

      expect((result as Err<List<Reaction>>).error.code, 'social.row_corrupt');
    });

    test('passes a transient failure through verbatim', () async {
      final repo = PostgresReactionRepository(_fails());

      final result = await repo.listReactionsForRound(_gId, _rId);

      expect((result as Err<List<Reaction>>).error.kind, ErrorKind.transient);
    });
  });

  group('PostgresReactionRepository.removeReaction', () {
    test(
      'DELETE … RETURNING id → Ok(true) when a row was removed, bound',
      () async {
        final conn = _rows([
          {'id': _reactionId},
        ]);
        final repo = PostgresReactionRepository(conn);

        final result = await repo.removeReaction(_gId, _rId, _uId);

        expect((result as Ok<bool>).value, isTrue);
        expect(conn.sqls.single, contains('DELETE FROM social.reactions'));
        expect(conn.sqls.single, contains('RETURNING id'));
        expect(conn.parameters.single, {
          'group_id': _groupId,
          'round_id': _roundId,
          'user_id': _userId,
        });
      },
    );

    test('Ok(false) when there was nothing to remove (idempotent)', () async {
      final repo = PostgresReactionRepository(_rows(const []));

      final result = await repo.removeReaction(_gId, _rId, _uId);

      expect((result as Ok<bool>).value, isFalse);
    });

    test('passes a transient failure through verbatim', () async {
      final repo = PostgresReactionRepository(_fails());

      final result = await repo.removeReaction(_gId, _rId, _uId);

      expect((result as Err<bool>).error.kind, ErrorKind.transient);
    });
  });
}
