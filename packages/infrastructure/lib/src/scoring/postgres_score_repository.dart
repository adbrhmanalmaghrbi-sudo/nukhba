import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:infrastructure/src/db/postgres_connection.dart';
// `postgres` exports its own `Result`; we only need its exception hierarchy
// here (to read the SQLSTATE `code`/`constraintName` off a `ServerException`),
// so hide `Result` to keep `Result<T>` unambiguously our `shared` union.
import 'package:postgres/postgres.dart' hide Result;
import 'package:shared/shared.dart';

/// Postgres-backed [ScoreRepository] over the `scoring.round_scores` +
/// `scoring.round_score_fixtures` tables (Database ADR; migration
/// `0004_scoring.sql`).
///
/// A score is a **server-owned read value** (Axioms 2/5): only the scoring
/// use-case (fed by the pure `Scoring.scoreRound`) produces the [RoundScore]s
/// written here. The parent `round_scores` row carries the derived total and
/// the frozen ruleset version; the child `round_score_fixtures` rows carry the
/// per-fixture grade + points in the prediction's fixture order.
///
/// The adapter is *total* (Application ADR §2): it never throws. It speaks only
/// in the domain [RoundScore] aggregate and typed ids; SQL and rows never leak.
///
/// Atomicity (Axiom 5): [saveRoundScores] writes **all** parents and children
/// for the round inside a single [PostgresConnection.runInTransaction] — a
/// mid-write failure rolls the whole batch back, so a round is never left
/// half-scored (a corrupted competitive record). Re-scoring the same round
/// upserts each `(round, participant)` parent in place and replaces its children
/// (delete + reinsert), so scoring is idempotent (Axiom 4: one score per
/// participant per round, never a second row).
///
/// All queries bind values through `@named` parameters (Security ADR §2).
final class PostgresScoreRepository implements ScoreRepository {
  /// Creates the repository over an open [PostgresConnection].
  const PostgresScoreRepository(this._connection);

  final PostgresConnection _connection;

  // --------------------------------------------------------------------------
  // saveRoundScores — atomic, idempotent batch write of a round's scores
  // --------------------------------------------------------------------------

  // ON CONFLICT (round_id, participant_id) refreshes the derived total and the
  // ruleset version in place — the idempotent-replay backstop for re-scoring
  // (Axiom 4). `scored_at` is refreshed to the write instant.
  static const String _upsertRoundScoreSql = '''
INSERT INTO scoring.round_scores
  (round_id, participant_id, ruleset_version, total_points, scored_at)
VALUES (@round_id, @participant_id, @ruleset_version, @total_points, now())
ON CONFLICT (round_id, participant_id) DO UPDATE SET
  ruleset_version = EXCLUDED.ruleset_version,
  total_points    = EXCLUDED.total_points,
  scored_at       = EXCLUDED.scored_at
''';

  static const String _deleteFixturesSql = '''
DELETE FROM scoring.round_score_fixtures
WHERE round_id = @round_id AND participant_id = @participant_id
''';

  static const String _insertFixtureSql = '''
INSERT INTO scoring.round_score_fixtures
  (round_id, participant_id, fixture_id, grade, points, display_order)
VALUES (@round_id, @participant_id, @fixture_id, @grade, @points, @display_order)
''';

  @override
  Future<Result<void>> saveRoundScores(List<RoundScore> scores) {
    if (scores.isEmpty) {
      // Nothing to persist (a round with no predictions is still validly
      // "scored"); avoid opening a transaction for a no-op.
      return Future.value(const Result.ok(null));
    }
    // Every parent + every child, in ONE transaction: a failure on any statement
    // rolls the whole round's scoring back, so the competitive record is never
    // left half-written (Axiom 5).
    return _connection.runInTransaction((tx) async {
      for (final score in scores) {
        final parent = await tx.query(
          _upsertRoundScoreSql,
          parameters: {
            'round_id': score.roundId.value,
            'participant_id': score.participantId.value,
            'ruleset_version': score.rulesetVersion,
            'total_points': score.totalPoints,
          },
        );
        final parentResult = _asVoid(parent);
        if (parentResult is Err<void>) {
          return parentResult;
        }

        // Replace the child breakdown in place (idempotent re-score): drop the
        // old rows, reinsert in the prediction's fixture order.
        final deleted = await tx.query(
          _deleteFixturesSql,
          parameters: {
            'round_id': score.roundId.value,
            'participant_id': score.participantId.value,
          },
        );
        final deleteResult = _asVoid(deleted);
        if (deleteResult is Err<void>) {
          return deleteResult;
        }

        for (var order = 0; order < score.fixtureResults.length; order++) {
          final fixtureResult = score.fixtureResults[order];
          final inserted = await tx.query(
            _insertFixtureSql,
            parameters: {
              'round_id': score.roundId.value,
              'participant_id': score.participantId.value,
              'fixture_id': fixtureResult.fixture.value,
              'grade': fixtureResult.grade.wireValue,
              'points': fixtureResult.points,
              'display_order': order,
            },
          );
          final childResult = _asVoid(inserted);
          if (childResult is Err<void>) {
            return childResult;
          }
        }
      }
      return const Result.ok(null);
    });
  }

  // --------------------------------------------------------------------------
  // listByRound — every participant's score for a round (participant-ordered)
  // --------------------------------------------------------------------------

  // Ordered by participant id for a stable read, then by the child's
  // display_order so each breakdown rebuilds in its stored (prediction) order.
  static const String _selectByRoundSql = '''
SELECT rs.round_id        AS round_id,
       rs.participant_id   AS participant_id,
       rs.ruleset_version  AS ruleset_version,
       rs.total_points     AS total_points,
       f.fixture_id        AS fixture_id,
       f.grade             AS grade,
       f.points            AS points,
       f.display_order     AS display_order
FROM scoring.round_scores rs
JOIN scoring.round_score_fixtures f
  ON f.round_id = rs.round_id AND f.participant_id = rs.participant_id
WHERE rs.round_id = @round_id
ORDER BY rs.participant_id ASC, f.display_order ASC
''';

  @override
  Future<Result<List<RoundScore>>> listByRound(RoundId roundId) async {
    final result = await _connection.query(
      _selectByRoundSql,
      parameters: {'round_id': roundId.value},
    );
    return switch (result) {
      Err<List<Map<String, dynamic>>>(:final error) => Result.err(error),
      Ok<List<Map<String, dynamic>>>(:final value) => _mapRoundScores(value),
    };
  }

  Result<List<RoundScore>> _mapRoundScores(List<Map<String, dynamic>> rows) {
    // Group the flat join by participant (the query orders parents by
    // participant id and children by display_order within each parent).
    final grouped = <String, List<Map<String, dynamic>>>{};
    final order = <String>[];
    for (final row in rows) {
      final key = row['participant_id']?.toString();
      if (key == null) {
        return Result.err(
          _corrupt('round_scores', 'participant_id', 'null in row'),
        );
      }
      final bucket = grouped[key];
      if (bucket == null) {
        grouped[key] = <Map<String, dynamic>>[row];
        order.add(key);
      } else {
        bucket.add(row);
      }
    }

    final scores = <RoundScore>[];
    for (final key in order) {
      final mapped = _mapOneScore(grouped[key]!);
      if (mapped is Err<RoundScore>) {
        return Result.err(mapped.error);
      }
      scores.add((mapped as Ok<RoundScore>).value);
    }
    return Result.ok(List<RoundScore>.unmodifiable(scores));
  }

  Result<RoundScore> _mapOneScore(List<Map<String, dynamic>> rows) {
    final first = rows.first;
    final roundIdResult = RoundId.tryParse(first['round_id']?.toString());
    final participantIdResult = ParticipantId.tryParse(
      first['participant_id']?.toString(),
    );
    final rulesetVersion = first['ruleset_version'];
    final totalPoints = first['total_points'];

    if (roundIdResult is Err<RoundId>) {
      return Result.err(
        _corrupt('round_scores', 'round_id', roundIdResult.error.message),
      );
    }
    if (participantIdResult is Err<ParticipantId>) {
      return Result.err(
        _corrupt(
          'round_scores',
          'participant_id',
          participantIdResult.error.message,
        ),
      );
    }
    if (rulesetVersion is! int) {
      return Result.err(
        _corrupt('round_scores', 'ruleset_version', 'not an integer'),
      );
    }
    if (totalPoints is! int) {
      return Result.err(
        _corrupt('round_scores', 'total_points', 'not an integer'),
      );
    }

    final fixturesResult = _mapFixtures(rows);
    if (fixturesResult is Err<List<FixtureScoreResult>>) {
      return Result.err(fixturesResult.error);
    }

    return Result.ok(
      RoundScore.fromStored(
        roundId: (roundIdResult as Ok<RoundId>).value,
        participantId: (participantIdResult as Ok<ParticipantId>).value,
        rulesetVersion: rulesetVersion,
        totalPoints: totalPoints,
        fixtureResults: (fixturesResult as Ok<List<FixtureScoreResult>>).value,
      ),
    );
  }

  Result<List<FixtureScoreResult>> _mapFixtures(
    List<Map<String, dynamic>> rows,
  ) {
    final fixtures = <FixtureScoreResult>[];
    for (final row in rows) {
      final fixtureResult = FixtureRef.tryParse(row['fixture_id']?.toString());
      final gradeResult = FixtureScoreGrade.tryParse(row['grade']?.toString());
      final points = row['points'];

      if (fixtureResult is Err<FixtureRef>) {
        return Result.err(
          _corrupt(
            'round_score_fixtures',
            'fixture_id',
            fixtureResult.error.message,
          ),
        );
      }
      if (gradeResult is Err<FixtureScoreGrade>) {
        return Result.err(
          _corrupt('round_score_fixtures', 'grade', gradeResult.error.message),
        );
      }
      if (points is! int) {
        return Result.err(
          _corrupt('round_score_fixtures', 'points', 'not an integer'),
        );
      }

      fixtures.add(
        FixtureScoreResult(
          fixture: (fixtureResult as Ok<FixtureRef>).value,
          grade: (gradeResult as Ok<FixtureScoreGrade>).value,
          points: points,
        ),
      );
    }
    if (fixtures.isEmpty) {
      // A stored round score with no fixture rows contradicts the domain
      // (a RoundScore always grades ≥1 fixture) and the JOIN — schema drift.
      return Result.err(
        _corrupt('round_score_fixtures', 'rows', 'round score has no fixtures'),
      );
    }
    return Result.ok(List<FixtureScoreResult>.unmodifiable(fixtures));
  }

  // --------------------------------------------------------------------------
  // Shared helpers (mirror PostgresPredictionRepository)
  // --------------------------------------------------------------------------

  Result<void> _asVoid(Result<List<Map<String, dynamic>>> result) {
    return switch (result) {
      Ok<List<Map<String, dynamic>>>() => const Result.ok(null),
      Err<List<Map<String, dynamic>>>(:final error) => Result.err(
        _reclassify(error),
      ),
    };
  }

  AppError _reclassify(AppError error) {
    final cause = error.cause;
    if (cause is! ServerException) {
      return error;
    }
    final code = cause.code;
    const integrityCodes = {'23505', '23503', '23514'};
    if (code == null || !integrityCodes.contains(code)) {
      return error;
    }
    final constraint = cause.constraintName;
    if (constraint == 'round_scores_round_id_fkey' ||
        constraint == 'round_score_fixtures_round_id_fkey') {
      return const AppError.invariant(
        'scoring.round_not_found',
        'Round not found',
      );
    }
    if (constraint == 'round_scores_participant_id_fkey' ||
        constraint == 'round_score_fixtures_participant_id_fkey') {
      return const AppError.invariant(
        'scoring.not_a_participant',
        'Participant not found',
      );
    }
    return const AppError.invariant(
      'scoring.integrity_violation',
      'The write violated a round-score integrity rule',
    );
  }

  static AppError _corrupt(String table, String field, String detail) =>
      AppError.transient(
        'scoring.row_corrupt',
        'Stored $table row has invalid $field: $detail',
      );
}
