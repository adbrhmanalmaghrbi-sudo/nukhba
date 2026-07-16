import 'package:domain/domain.dart';
import 'package:infrastructure/src/db/postgres_connection.dart';
import 'package:infrastructure/src/leaderboard/postgres_leaderboard_repository.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

/// Hermetic unit tests for [PostgresLeaderboardRepository].
///
/// These do NOT require a live database. They substitute a fake
/// [PostgresConnection] that replies to `query` with a scripted [Result], so we
/// drive every *pure* branch the adapter owns:
///   * the season-scoped SELECT over the projection VIEW (SQL shape, `@season_id`
///     binding, no ORDER BY — the domain ranks);
///   * row → [LeaderboardEntry] mapping (unranked, UTC joinedAt, int totals),
///     including a `bigint` total arriving as [BigInt] and a zero row
///     (enrolled-but-never-credited);
///   * verbatim pass-through of a transient query failure;
///   * corrupt-row mapping (`leaderboard.row_corrupt`) for a bad participant id,
///     a non-int total, and a non-UTC/absent joined_at.
///
/// The VIEW's own correctness (the season-scoped SUM/LEFT-JOIN) is verified
/// against real Postgres in the DB-gated integration test, since the SQL VIEW
/// cannot be exercised by a fake connection.

const _participantId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
const _participantId2 = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
const _seasonId = '55555555-5555-5555-5555-555555555555';

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
  ) async => action(this);

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

SeasonId get _sId => (SeasonId.tryParse(_seasonId) as Ok<SeasonId>).value;

Map<String, dynamic> _standingRow({
  String participant = _participantId,
  Object totalPoints = 4,
  Object entryCount = 1,
  Object joinedAt = '2026-07-01T00:00:00.000Z',
}) => {
  'participant_id': participant,
  'total_points': totalPoints,
  'entry_count': entryCount,
  'joined_at': joinedAt,
};

void main() {
  group('PostgresLeaderboardRepository.seasonStandings', () {
    test('maps rows to unranked entries and binds the season id', () async {
      final conn = _rows([
        _standingRow(
          participant: _participantId,
          totalPoints: 7,
          entryCount: 2,
        ),
        _standingRow(
          participant: _participantId2,
          totalPoints: 0,
          entryCount: 0,
          joinedAt: '2026-07-02T00:00:00.000Z',
        ),
      ]);
      final repo = PostgresLeaderboardRepository(conn);

      final result = await repo.seasonStandings(_sId);

      expect(result, isA<Ok<List<LeaderboardEntry>>>());
      final entries = (result as Ok<List<LeaderboardEntry>>).value;
      expect(entries.length, 2);

      final first = entries.first;
      expect(first.participantId, const ParticipantId(_participantId));
      expect(first.totalPoints, 7);
      expect(first.entryCount, 2);
      expect(first.joinedAt.isUtc, isTrue);
      // Unranked: the adapter never assigns a rank (the domain does).
      expect(first.isRanked, isFalse);
      expect(first.rank, 0);

      // A never-credited participant appears with a zero total (LEFT JOIN).
      final second = entries.last;
      expect(second.totalPoints, 0);
      expect(second.entryCount, 0);

      // SQL shape + binding; no ORDER BY (ranking lives in the domain).
      expect(conn.sqls.single, contains('FROM leaderboard.season_standings'));
      expect(conn.sqls.single, contains('WHERE season_id = @season_id'));
      expect(conn.sqls.single, isNot(contains('ORDER BY')));
      expect(conn.parameters.single, {'season_id': _seasonId});
    });

    test('reads a bigint total (SUM) and count arriving as BigInt', () async {
      final conn = _rows([
        _standingRow(totalPoints: BigInt.from(12), entryCount: BigInt.from(3)),
      ]);
      final repo = PostgresLeaderboardRepository(conn);

      final result = await repo.seasonStandings(_sId);

      final entries = (result as Ok<List<LeaderboardEntry>>).value;
      expect(entries.single.totalPoints, 12);
      expect(entries.single.entryCount, 3);
    });

    test('an empty board (no participants) is Ok(empty)', () async {
      final repo = PostgresLeaderboardRepository(_rows(const []));

      final result = await repo.seasonStandings(_sId);

      expect(result, isA<Ok<List<LeaderboardEntry>>>());
      expect((result as Ok<List<LeaderboardEntry>>).value, isEmpty);
    });

    test('passes a transient query failure through verbatim', () async {
      final repo = PostgresLeaderboardRepository(_fails());

      final result = await repo.seasonStandings(_sId);

      expect(result, isA<Err<List<LeaderboardEntry>>>());
      expect(
        (result as Err<List<LeaderboardEntry>>).error.kind,
        ErrorKind.transient,
      );
    });

    test('maps a corrupt participant id to a transient row_corrupt', () async {
      final repo = PostgresLeaderboardRepository(
        _rows([_standingRow()..['participant_id'] = 'not-a-uuid']),
      );

      final result = await repo.seasonStandings(_sId);

      final error = (result as Err<List<LeaderboardEntry>>).error;
      expect(error.kind, ErrorKind.transient);
      expect(error.code, 'leaderboard.row_corrupt');
    });

    test('maps a non-integer total to a transient row_corrupt', () async {
      final repo = PostgresLeaderboardRepository(
        _rows([_standingRow()..['total_points'] = 'nonsense']),
      );

      final result = await repo.seasonStandings(_sId);

      final error = (result as Err<List<LeaderboardEntry>>).error;
      expect(error.kind, ErrorKind.transient);
      expect(error.code, 'leaderboard.row_corrupt');
    });

    test('maps an absent joined_at to a transient row_corrupt', () async {
      final repo = PostgresLeaderboardRepository(
        _rows([_standingRow()..['joined_at'] = 42]),
      );

      final result = await repo.seasonStandings(_sId);

      final error = (result as Err<List<LeaderboardEntry>>).error;
      expect(error.kind, ErrorKind.transient);
      expect(error.code, 'leaderboard.row_corrupt');
    });
  });
}
