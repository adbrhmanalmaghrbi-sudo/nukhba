import 'package:domain/domain.dart';
import 'package:infrastructure/src/competition/postgres_competition_repository.dart';
import 'package:infrastructure/src/db/postgres_connection.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

/// Hermetic unit tests for [PostgresCompetitionRepository].
///
/// These do NOT require a live database. They substitute a fake
/// [PostgresConnection] whose [query] returns canned [Result]s, so we can drive
/// every *pure* branch the adapter owns: the row → aggregate mapping (happy
/// path), the "not found" / "empty means not-joined" outcomes, the
/// row-corruption mapping, the parameter binding contract, and the verbatim
/// pass-through of a transient query error.
///
/// The one branch that genuinely needs the driver — reclassifying a
/// `postgres` [ServerException] into a domain `invariant` conflict via the
/// violated constraint name — is deliberately NOT exercised here: the driver's
/// `ServerException` has no public constructor, so that path can only be
/// verified honestly against real Postgres (see the DB-gated integration test
/// `postgres_competition_repository_integration_test.dart`). Splitting the two
/// keeps the unit run fully hermetic while still asserting the mapping logic
/// end-to-end where it can actually happen.

const _competitionId = '11111111-1111-1111-1111-111111111111';
const _seasonId = '22222222-2222-2222-2222-222222222222';
const _roundId = '33333333-3333-3333-3333-333333333333';
const _participantId = '44444444-4444-4444-4444-444444444444';
const _userId = '55555555-5555-5555-5555-555555555555';

/// A [PostgresConnection] test double that records the SQL + parameters it was
/// asked to run and replies with a scripted [Result]. It never touches a real
/// pool (the driver field stays private and unreached), so the whole test is
/// hermetic.
final class _FakeConnection implements PostgresConnection {
  _FakeConnection(this._response);

  final Result<List<Map<String, dynamic>>> _response;

  String? lastSql;
  Map<String, Object?>? lastParameters;
  int calls = 0;

  @override
  Future<Result<List<Map<String, dynamic>>>> query(
    String sql, {
    Map<String, Object?> parameters = const {},
  }) async {
    calls++;
    lastSql = sql;
    lastParameters = parameters;
    return _response;
  }

  @override
  Future<Result<bool>> ping() async => const Result.ok(true);

  @override
  Future<Result<T>> runInTransaction<T>(
    Future<Result<T>> Function(DbExecutor tx) action,
  ) =>
      // The competition adapter never opens a transaction; this passthrough
      // exists only to satisfy the widened PostgresConnection surface. The
      // action runs against this same fake, so its scripted query response is
      // reused verbatim (an Err propagates as the transaction outcome).
      action(this);

  @override
  Future<void> close() async {}
}

/// Convenience: a connection that answers a read with [rows].
_FakeConnection _rows(List<Map<String, dynamic>> rows) =>
    _FakeConnection(Result.ok(rows));

/// Convenience: a connection whose query fails transiently (the driver wraps
/// any fault as `AppError.transient`).
_FakeConnection _fails() => _FakeConnection(
  const Result.err(
    AppError.transient('db.query_failed', 'Database query failed'),
  ),
);

CompetitionId get _cId =>
    (CompetitionId.tryParse(_competitionId) as Ok<CompetitionId>).value;
SeasonId get _sId => (SeasonId.tryParse(_seasonId) as Ok<SeasonId>).value;
RoundId get _rId => (RoundId.tryParse(_roundId) as Ok<RoundId>).value;
UserId get _uId => (UserId.tryParse(_userId) as Ok<UserId>).value;

void main() {
  group('PostgresCompetitionRepository — writes bind, never concatenate', () {
    test('saveCompetition binds every value by @named parameter', () async {
      final conn = _rows(const []);
      final repo = PostgresCompetitionRepository(conn);

      final competition = Competition.fromStored(
        id: _cId,
        name: 'Premier League Predictor',
        format: FormatType.footballScoreline,
        visibility: CompetitionVisibility.public,
      );

      final result = await repo.saveCompetition(competition);

      expect(result, isA<Ok<void>>());
      // The name (untrusted display text) is carried as a bound parameter, not
      // spliced into SQL (Security ADR §2).
      expect(conn.lastParameters!['id'], _competitionId);
      expect(conn.lastParameters!['name'], 'Premier League Predictor');
      expect(conn.lastParameters!['format'], 'football_scoreline');
      expect(conn.lastParameters!['visibility'], 'public');
      expect(conn.lastSql, contains('@name'));
      expect(conn.lastSql, isNot(contains('Premier League Predictor')));
    });

    test(
      'saveRound encodes the ruleset snapshot as JSON text + version',
      () async {
        final conn = _rows(const []);
        final repo = PostgresCompetitionRepository(conn);

        final snapshot =
            (RulesetSnapshot.create(
                      payload: const {'exact': 3, 'outcome': 1},
                      rulesetVersion: 7,
                    )
                    as Ok<RulesetSnapshot>)
                .value;
        final round = Round.fromStored(
          id: _rId,
          seasonId: _sId,
          sequence: 1,
          predictionDeadline: DateTime.utc(2026, 8, 1, 12),
          status: RoundStatus.open,
          ruleset: snapshot,
        );

        final result = await repo.saveRound(round);

        expect(result, isA<Ok<void>>());
        expect(conn.lastParameters!['ruleset_version'], 7);
        // Structured payload is written as canonical JSON text (cast to jsonb
        // server-side), so it round-trips verbatim.
        expect(
          conn.lastParameters!['ruleset_snapshot'],
          '{"exact":3,"outcome":1}',
        );
        expect(conn.lastParameters!['status'], 'open');
        // UTC instant serialized as ISO-8601 for timestamptz binding.
        expect(
          conn.lastParameters!['prediction_deadline'],
          DateTime.utc(2026, 8, 1, 12).toIso8601String(),
        );
      },
    );

    test('saveParticipant surfaces a transient query fault unchanged', () async {
      final repo = PostgresCompetitionRepository(_fails());

      final participant =
          (Participant.join(
                    id:
                        (ParticipantId.tryParse(_participantId)
                                as Ok<ParticipantId>)
                            .value,
                    seasonId: _sId,
                    userId: _uId,
                    joinedAt: DateTime.utc(2026, 7, 1),
                  )
                  as Ok<Participant>)
              .value;

      final result = await repo.saveParticipant(participant);

      final err = (result as Err<void>).error;
      // A real infrastructure fault (not an integrity violation) stays
      // retryable — the adapter must NOT reclassify it as a business conflict.
      expect(err.kind, ErrorKind.transient);
      expect(err.code, 'db.query_failed');
    });
  });

  group('findCompetition', () {
    test('maps a stored row into the Competition aggregate', () async {
      final repo = PostgresCompetitionRepository(
        _rows([
          {
            'id': _competitionId,
            'name': 'World Cup Predictor',
            'format': 'football_scoreline',
            'visibility': 'private',
          },
        ]),
      );

      final result = await repo.findCompetition(_cId);

      final competition = (result as Ok<Competition>).value;
      expect(competition.id.value, _competitionId);
      expect(competition.name, 'World Cup Predictor');
      expect(competition.format, FormatType.footballScoreline);
      expect(competition.visibility, CompetitionVisibility.private);
    });

    test(
      'an empty result is a not_found invariant, not a transient miss',
      () async {
        final repo = PostgresCompetitionRepository(_rows(const []));

        final result = await repo.findCompetition(_cId);

        final err = (result as Err<Competition>).error;
        expect(err.kind, ErrorKind.invariant);
        expect(err.code, 'competition.not_found');
      },
    );

    test(
      'a corrupt stored enum maps to a transient row_corrupt fault',
      () async {
        final repo = PostgresCompetitionRepository(
          _rows([
            {
              'id': _competitionId,
              'name': 'Broken',
              'format': 'chess', // not a known FormatType wire value
              'visibility': 'public',
            },
          ]),
        );

        final result = await repo.findCompetition(_cId);

        final err = (result as Err<Competition>).error;
        // Schema drift / corruption is an infrastructure fault, not the caller's
        // fault — surfaced as transient, never invariant.
        expect(err.kind, ErrorKind.transient);
        expect(err.code, 'competition.row_corrupt');
      },
    );

    test('a transient query error is propagated verbatim', () async {
      final repo = PostgresCompetitionRepository(_fails());

      final result = await repo.findCompetition(_cId);

      final err = (result as Err<Competition>).error;
      expect(err.kind, ErrorKind.transient);
      expect(err.code, 'db.query_failed');
    });
  });

  group('findSeason', () {
    test('maps a stored row into the CompetitionSeason aggregate', () async {
      final repo = PostgresCompetitionRepository(
        _rows([
          {
            'id': _seasonId,
            'competition_id': _competitionId,
            'label': '2026/27',
          },
        ]),
      );

      final season =
          (await repo.findSeason(_sId) as Ok<CompetitionSeason>).value;
      expect(season.id.value, _seasonId);
      expect(season.competitionId.value, _competitionId);
      expect(season.label, '2026/27');
    });

    test('empty result maps to season_not_found invariant', () async {
      final repo = PostgresCompetitionRepository(_rows(const []));

      final err = (await repo.findSeason(_sId) as Err<CompetitionSeason>).error;
      expect(err.kind, ErrorKind.invariant);
      expect(err.code, 'competition.season_not_found');
    });
  });

  group('findRound', () {
    Map<String, dynamic> roundRow({
      Object? snapshot = '{"exact":3}',
      Object? version = 2,
      Object? deadline,
    }) => {
      'id': _roundId,
      'season_id': _seasonId,
      'sequence': 1,
      'prediction_deadline': deadline ?? DateTime.utc(2026, 8, 1),
      'status': 'open',
      'ruleset_snapshot': snapshot,
      'ruleset_version': version,
    };

    test('maps a stored row (JSONB as Map) into the Round aggregate', () async {
      final repo = PostgresCompetitionRepository(
        _rows([
          roundRow(snapshot: const {'exact': 3, 'outcome': 1}),
        ]),
      );

      final round = (await repo.findRound(_rId) as Ok<Round>).value;
      expect(round.id.value, _roundId);
      expect(round.seasonId.value, _seasonId);
      expect(round.sequence, 1);
      expect(round.status, RoundStatus.open);
      expect(round.ruleset.rulesetVersion, 2);
      expect(round.ruleset.payload, const {'exact': 3, 'outcome': 1});
      // The domain guarantees UTC regardless of the stored kind.
      expect(round.predictionDeadline.isUtc, isTrue);
    });

    test('accepts a JSONB snapshot delivered as a JSON string', () async {
      final repo = PostgresCompetitionRepository(
        _rows([roundRow(snapshot: '{"exact":5}')]),
      );

      final round = (await repo.findRound(_rId) as Ok<Round>).value;
      expect(round.ruleset.payload, const {'exact': 5});
    });

    test('empty result maps to round_not_found invariant', () async {
      final repo = PostgresCompetitionRepository(_rows(const []));

      final err = (await repo.findRound(_rId) as Err<Round>).error;
      expect(err.kind, ErrorKind.invariant);
      expect(err.code, 'competition.round_not_found');
    });

    test('a non-integer sequence maps to row_corrupt', () async {
      final repo = PostgresCompetitionRepository(
        _rows([
          {...roundRow(), 'sequence': 'one'},
        ]),
      );

      final err = (await repo.findRound(_rId) as Err<Round>).error;
      expect(err.kind, ErrorKind.transient);
      expect(err.code, 'competition.row_corrupt');
    });

    test('an unparseable ruleset snapshot maps to row_corrupt', () async {
      final repo = PostgresCompetitionRepository(
        _rows([roundRow(snapshot: 'not-json')]),
      );

      final err = (await repo.findRound(_rId) as Err<Round>).error;
      expect(err.kind, ErrorKind.transient);
      expect(err.code, 'competition.row_corrupt');
    });
  });

  group('findParticipant', () {
    test('maps a stored row into the Participant aggregate', () async {
      final repo = PostgresCompetitionRepository(
        _rows([
          {
            'id': _participantId,
            'season_id': _seasonId,
            'user_id': _userId,
            'status': 'active',
            'joined_at': DateTime.utc(2026, 7, 1, 9),
          },
        ]),
      );

      final participant =
          (await repo.findParticipant(_sId, _uId) as Ok<Participant?>).value!;
      expect(participant.id.value, _participantId);
      expect(participant.userId.value, _userId);
      expect(participant.status, ParticipantStatus.active);
      expect(participant.joinedAt.isUtc, isTrue);
    });

    test('absence is a successful Ok(null), not an error', () async {
      final conn = _rows(const []);
      final repo = PostgresCompetitionRepository(conn);

      final result = await repo.findParticipant(_sId, _uId);

      // The join use-case relies on this to decide idempotently.
      expect((result as Ok<Participant?>).value, isNull);
      // The lookup binds both keys, never concatenates them.
      expect(conn.lastParameters!['season_id'], _seasonId);
      expect(conn.lastParameters!['user_id'], _userId);
    });

    test('a transient query error is propagated verbatim', () async {
      final repo = PostgresCompetitionRepository(_fails());

      final err =
          (await repo.findParticipant(_sId, _uId) as Err<Participant?>).error;
      expect(err.kind, ErrorKind.transient);
      expect(err.code, 'db.query_failed');
    });
  });

  group('updateRoundStatus (optimistic-concurrency guard)', () {
    Round lockedRound() {
      final snapshot =
          (RulesetSnapshot.create(
                    payload: const {'exact': 3},
                    rulesetVersion: 1,
                  )
                  as Ok<RulesetSnapshot>)
              .value;
      return Round.fromStored(
        id: _rId,
        seasonId: _sId,
        sequence: 1,
        predictionDeadline: DateTime.utc(2026, 8, 1),
        status: RoundStatus.locked,
        ruleset: snapshot,
      );
    }

    test('a returned row means the guarded update won', () async {
      final conn = _rows([
        {'id': _roundId},
      ]);
      final repo = PostgresCompetitionRepository(conn);

      final result = await repo.updateRoundStatus(
        lockedRound(),
        RoundStatus.open,
      );

      expect(result, isA<Ok<void>>());
      // Guard is keyed on the expected prior status.
      expect(conn.lastParameters!['expected'], 'open');
      expect(conn.lastParameters!['next'], 'locked');
      expect(conn.lastSql, contains('AND status = @expected'));
    });

    test(
      'zero rows updated is a round_transition_conflict invariant',
      () async {
        final repo = PostgresCompetitionRepository(_rows(const []));

        final result = await repo.updateRoundStatus(
          lockedRound(),
          RoundStatus.open,
        );

        final err = (result as Err<void>).error;
        // A concurrent transition won the race — reported as the documented
        // conflict, not a silent no-op.
        expect(err.kind, ErrorKind.invariant);
        expect(err.code, 'competition.round_transition_conflict');
      },
    );

    test('a transient query error is propagated', () async {
      final repo = PostgresCompetitionRepository(_fails());

      final result = await repo.updateRoundStatus(
        lockedRound(),
        RoundStatus.open,
      );

      final err = (result as Err<void>).error;
      expect(err.kind, ErrorKind.transient);
      expect(err.code, 'db.query_failed');
    });
  });
}
