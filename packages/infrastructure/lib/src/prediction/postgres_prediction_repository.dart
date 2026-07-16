import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:infrastructure/src/db/postgres_connection.dart';
// `postgres` exports its own `Result`; we only need its exception hierarchy
// here (to read the SQLSTATE `code` / `constraintName` off a `ServerException`),
// so hide `Result` to keep `Result<T>` unambiguously our `shared` union.
import 'package:postgres/postgres.dart' hide Result;
import 'package:shared/shared.dart';

/// Postgres-backed [PredictionRepository] over the `prediction.*` tables
/// (Database ADR §2.1; migration `0003_prediction.sql`) plus a read-only
/// projection of `competition.round_fixtures` (owned by migration 0002).
///
/// The Prediction aggregate is deliberately **separate** from Competition
/// (Database ADR §1 & §2.1): prediction writes are the platform's
/// highest-volume path and must never contend on the Competition aggregate, so
/// this is its own adapter over its own tables. It reads the round's fixture
/// composition (`listRoundFixtures`) from the Competition-owned link table
/// only — never writing across the boundary — so the frozen Competition port
/// stays untouched.
///
/// The adapter is *total* (Application ADR §2): it never throws — every outcome
/// is a typed [Result]. It speaks only in domain aggregates and typed ids; SQL
/// and rows never leak past this boundary, so the use-cases stay pure and
/// testable against an in-memory fake.
///
/// Error mapping (the port's general contract):
/// * The unique `(participant_id, round_id)` violation (`23505`) — the physical
///   "predict once" backstop (Axiom 4/6) — is surfaced as [ErrorKind.invariant]
///   `prediction.already_submitted`, exactly the code the [SubmitPrediction]
///   use-case pivots on to converge a lost insert race into an amend.
/// * A foreign-key violation (`23503`) to an absent round or participant is an
///   [ErrorKind.invariant] `*.not_found` precondition failure — the caller named
///   something that does not exist.
/// * A check/trigger rejection (`23514`, e.g. the "no submit after lock"
///   backstop, the goal-range check) is an [ErrorKind.invariant] conflict.
/// * A genuinely transient/infrastructure failure stays [ErrorKind.transient]
///   (retryable), exactly as [PostgresConnection.query] classified it.
///
/// All queries bind values through `@named` parameters (Security ADR §2): no
/// untrusted value is ever concatenated into SQL.
final class PostgresPredictionRepository implements PredictionRepository {
  /// Creates the repository over an open [PostgresConnection].
  const PostgresPredictionRepository(this._connection);

  final PostgresConnection _connection;

  // --------------------------------------------------------------------------
  // findByRoundAndParticipant — the idempotency + "get my prediction" read
  // --------------------------------------------------------------------------

  // A prediction and its fixture-score children are read in one round-trip.
  // The parent columns repeat across the joined rows; the ordered child rows
  // rebuild the forecast in its stored order (order-significant equality —
  // FixtureScorePrediction list is position-comparable). A LEFT JOIN is not
  // needed: a stored prediction always has ≥1 score (domain + DB check), but a
  // defensively empty child set would surface as row-corrupt below.
  static const String _selectByRoundAndParticipantSql = '''
SELECT p.id            AS prediction_id,
       p.round_id       AS round_id,
       p.participant_id AS participant_id,
       p.submitted_at   AS submitted_at,
       s.fixture_id     AS fixture_id,
       s.home_goals     AS home_goals,
       s.away_goals     AS away_goals,
       s.display_order  AS display_order
FROM prediction.predictions p
JOIN prediction.prediction_scores s ON s.prediction_id = p.id
WHERE p.round_id = @round_id AND p.participant_id = @participant_id
ORDER BY s.display_order ASC
''';

  @override
  Future<Result<PredictionView?>> findByRoundAndParticipant(
    RoundId roundId,
    ParticipantId participantId,
  ) async {
    final result = await _connection.query(
      _selectByRoundAndParticipantSql,
      parameters: {
        'round_id': roundId.value,
        'participant_id': participantId.value,
      },
    );
    return switch (result) {
      Err<List<Map<String, dynamic>>>(:final error) => Result.err(error),
      // Absence is a normal, successful "not yet predicted" outcome (Ok(null)),
      // not an error — the submit use-case relies on this to insert-vs-amend.
      Ok<List<Map<String, dynamic>>>(:final value) =>
        value.isEmpty ? const Result.ok(null) : _mapPrediction(value),
    };
  }

  Result<PredictionView?> _mapPrediction(List<Map<String, dynamic>> rows) {
    final first = rows.first;
    final idResult = PredictionId.tryParse(first['prediction_id']?.toString());
    final roundIdResult = RoundId.tryParse(first['round_id']?.toString());
    final participantIdResult = ParticipantId.tryParse(
      first['participant_id']?.toString(),
    );

    if (idResult is Err<PredictionId>) {
      return Result.err(_corrupt('predictions', 'id', idResult.error.message));
    }
    if (roundIdResult is Err<RoundId>) {
      return Result.err(
        _corrupt('predictions', 'round_id', roundIdResult.error.message),
      );
    }
    if (participantIdResult is Err<ParticipantId>) {
      return Result.err(
        _corrupt(
          'predictions',
          'participant_id',
          participantIdResult.error.message,
        ),
      );
    }

    final submittedAtResult = _submittedAtOf(first);
    if (submittedAtResult is Err<DateTime>) {
      return Result.err(submittedAtResult.error);
    }

    final scoresResult = _mapScores(rows);
    if (scoresResult is Err<List<FixtureScorePrediction>>) {
      return Result.err(scoresResult.error);
    }

    return Result.ok(
      PredictionView(
        prediction: Prediction.fromStored(
          id: (idResult as Ok<PredictionId>).value,
          roundId: (roundIdResult as Ok<RoundId>).value,
          participantId: (participantIdResult as Ok<ParticipantId>).value,
          scores: (scoresResult as Ok<List<FixtureScorePrediction>>).value,
        ),
        submittedAt: (submittedAtResult as Ok<DateTime>).value,
      ),
    );
  }

  /// Reads the stored `submitted_at` from a row as a UTC [DateTime].
  ///
  /// The `postgres` 3.5.x driver decodes a `timestamptz` column to a Dart
  /// [DateTime] already; a driver that returns an ISO-8601 string (or a row
  /// projected through a text codec) is parsed defensively. Anything else is
  /// schema drift / corruption — surfaced as transient, not the caller's fault.
  Result<DateTime> _submittedAtOf(Map<String, dynamic> row) {
    final raw = row['submitted_at'];
    if (raw is DateTime) {
      return Result.ok(raw.toUtc());
    }
    if (raw is String) {
      final parsed = DateTime.tryParse(raw);
      if (parsed != null) {
        return Result.ok(parsed.toUtc());
      }
    }
    return Result.err(
      _corrupt('predictions', 'submitted_at', 'not a timestamp'),
    );
  }

  Result<List<FixtureScorePrediction>> _mapScores(
    List<Map<String, dynamic>> rows,
  ) {
    final scores = <FixtureScorePrediction>[];
    for (final row in rows) {
      final fixtureResult = FixtureRef.tryParse(row['fixture_id']?.toString());
      final homeGoals = row['home_goals'];
      final awayGoals = row['away_goals'];

      if (fixtureResult is Err<FixtureRef>) {
        return Result.err(
          _corrupt(
            'prediction_scores',
            'fixture_id',
            fixtureResult.error.message,
          ),
        );
      }
      if (homeGoals is! int) {
        return Result.err(
          _corrupt('prediction_scores', 'home_goals', 'not an integer'),
        );
      }
      if (awayGoals is! int) {
        return Result.err(
          _corrupt('prediction_scores', 'away_goals', 'not an integer'),
        );
      }

      scores.add(
        FixtureScorePrediction.fromStored(
          fixture: (fixtureResult as Ok<FixtureRef>).value,
          homeGoals: homeGoals,
          awayGoals: awayGoals,
        ),
      );
    }
    if (scores.isEmpty) {
      // A stored prediction with no child scores contradicts the domain
      // invariant and the DB (a submission always writes ≥1 score) — schema
      // drift / corruption, not the caller's fault.
      return Result.err(
        _corrupt('prediction_scores', 'rows', 'prediction has no scores'),
      );
    }
    return Result.ok(List<FixtureScorePrediction>.unmodifiable(scores));
  }

  // --------------------------------------------------------------------------
  // save — first submission (insert parent + child score rows, ATOMICALLY)
  //
  // The parent row and every child score row are written inside a single
  // transaction (via runInTransaction): all statements commit together or none
  // do, so a mid-write failure leaves no orphaned parent and no partial
  // forecast (Axiom 5). The write helpers take the transaction's DbExecutor.
  // --------------------------------------------------------------------------

  static const String _insertPredictionSql = '''
INSERT INTO prediction.predictions
  (id, round_id, participant_id, submitted_at)
VALUES (@id, @round_id, @participant_id, @submitted_at)
''';

  static const String _insertScoreSql = '''
INSERT INTO prediction.prediction_scores
  (prediction_id, fixture_id, home_goals, away_goals, display_order)
VALUES (@prediction_id, @fixture_id, @home_goals, @away_goals, @display_order)
''';

  @override
  Future<Result<void>> save(Prediction prediction, DateTime submittedAt) {
    // Parent row + every child score row are written in ONE transaction: a
    // failure on any statement (a lost unique-insert race, the "no write after
    // lock" trigger, a goal-range check) rolls the whole write back, so a
    // half-written forecast can never persist (Axiom 5: the competitive record
    // is the asset to protect).
    return _connection.runInTransaction((tx) async {
      final parent = await tx.query(
        _insertPredictionSql,
        parameters: {
          'id': prediction.id.value,
          'round_id': prediction.roundId.value,
          'participant_id': prediction.participantId.value,
          // The use-case supplies a UTC instant; timestamptz stores the instant.
          'submitted_at': submittedAt.toUtc().toIso8601String(),
        },
      );
      final parentResult = _asVoid(
        parent,
        onConstraint: _onPredictionConstraint,
      );
      if (parentResult is Err<void>) {
        return parentResult;
      }
      return _insertScores(tx, prediction);
    });
  }

  Future<Result<void>> _insertScores(
    DbExecutor tx,
    Prediction prediction,
  ) async {
    for (var order = 0; order < prediction.scores.length; order++) {
      final score = prediction.scores[order];
      final inserted = await tx.query(
        _insertScoreSql,
        parameters: {
          'prediction_id': prediction.id.value,
          'fixture_id': score.fixture.value,
          'home_goals': score.homeGoals,
          'away_goals': score.awayGoals,
          'display_order': order,
        },
      );
      final result = _asVoid(inserted, onConstraint: _onScoreConstraint);
      if (result is Err<void>) {
        return result;
      }
    }
    return const Result.ok(null);
  }

  // --------------------------------------------------------------------------
  // update — amendment (refresh submitted_at, replace child score rows)
  // --------------------------------------------------------------------------

  // Guarded on identity: `RETURNING` distinguishes "no row" (deleted between
  // read and update) from a driver error, so an amendment of a vanished
  // prediction surfaces as the documented `prediction.not_found` conflict.
  static const String _updatePredictionSql = '''
UPDATE prediction.predictions
SET submitted_at = @submitted_at
WHERE id = @id
RETURNING id
''';

  static const String _deleteScoresSql = '''
DELETE FROM prediction.prediction_scores WHERE prediction_id = @prediction_id
''';

  @override
  Future<Result<void>> update(Prediction prediction, DateTime submittedAt) {
    // Parent refresh + child delete + child reinsert in ONE transaction: an
    // amendment must never leave the row with a fresh `submitted_at` but a
    // half-replaced forecast, nor lose the old scores while failing to write the
    // new ones (Axiom 4: the amendment is the same, always-complete row).
    return _connection.runInTransaction((tx) async {
      final updated = await tx.query(
        _updatePredictionSql,
        parameters: {
          'id': prediction.id.value,
          'submitted_at': submittedAt.toUtc().toIso8601String(),
        },
      );
      final guarded = switch (updated) {
        Err<List<Map<String, dynamic>>>(:final error) => Result<void>.err(
          _reclassify(error, onConstraint: _onPredictionConstraint),
        ),
        // Zero rows updated: the prediction no longer exists (deleted between
        // the use-case's read and this write). Surface the documented conflict;
        // returning Err rolls the transaction back (nothing was written yet).
        Ok<List<Map<String, dynamic>>>(:final value) =>
          value.isEmpty
              ? const Result<void>.err(
                  AppError.invariant(
                    'prediction.not_found',
                    'Prediction no longer exists',
                  ),
                )
              : const Result<void>.ok(null),
      };
      if (guarded is Err<void>) {
        return guarded;
      }

      // Replace the forecast in place: drop the old child rows, write the new
      // ones. The amendment is the same prediction row (Axiom 4), never a
      // second prediction. `display_order` is re-derived from the new list
      // order so the stored forecast round-trips in the amended order.
      final deleted = await tx.query(
        _deleteScoresSql,
        parameters: {'prediction_id': prediction.id.value},
      );
      final deleteResult = _asVoid(deleted, onConstraint: (_) => null);
      if (deleteResult is Err<void>) {
        return deleteResult;
      }
      return _insertScores(tx, prediction);
    });
  }

  // --------------------------------------------------------------------------
  // listByRound — every participant's prediction for a round (locked-read only)
  // --------------------------------------------------------------------------

  // Ordered by submission instant then prediction id for a stable read, then by
  // the child score's display_order so each forecast rebuilds in its stored
  // order. The two-level ordering lets a single pass group child rows under
  // their parent while preserving both the inter-prediction and intra-forecast
  // ordering the port documents.
  static const String _selectByRoundSql = '''
SELECT p.id            AS prediction_id,
       p.round_id       AS round_id,
       p.participant_id AS participant_id,
       p.submitted_at   AS submitted_at,
       s.fixture_id     AS fixture_id,
       s.home_goals     AS home_goals,
       s.away_goals     AS away_goals,
       s.display_order  AS display_order
FROM prediction.predictions p
JOIN prediction.prediction_scores s ON s.prediction_id = p.id
WHERE p.round_id = @round_id
ORDER BY p.submitted_at ASC, p.id ASC, s.display_order ASC
''';

  @override
  Future<Result<List<PredictionView>>> listByRound(RoundId roundId) async {
    final result = await _connection.query(
      _selectByRoundSql,
      parameters: {'round_id': roundId.value},
    );
    return switch (result) {
      Err<List<Map<String, dynamic>>>(:final error) => Result.err(error),
      Ok<List<Map<String, dynamic>>>(:final value) => _mapPredictionList(value),
    };
  }

  Result<List<PredictionView>> _mapPredictionList(
    List<Map<String, dynamic>> rows,
  ) {
    // Group the flat join result by prediction id, preserving first-seen order
    // (the query already orders parents by submitted_at then id, and children
    // by display_order within each parent).
    final grouped = <String, List<Map<String, dynamic>>>{};
    final order = <String>[];
    for (final row in rows) {
      final key = row['prediction_id']?.toString();
      if (key == null) {
        return Result.err(
          _corrupt('predictions', 'id', 'null prediction id in row'),
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

    final predictions = <PredictionView>[];
    for (final key in order) {
      final mapped = _mapPrediction(grouped[key]!);
      if (mapped is Err<PredictionView?>) {
        return Result.err(mapped.error);
      }
      predictions.add((mapped as Ok<PredictionView?>).value!);
    }
    return Result.ok(List<PredictionView>.unmodifiable(predictions));
  }

  // --------------------------------------------------------------------------
  // listRoundFixtures — read-only projection of the Competition-owned link
  // --------------------------------------------------------------------------

  static const String _selectRoundFixturesSql = '''
SELECT round_id, fixture_id, display_order
FROM competition.round_fixtures
WHERE round_id = @round_id
ORDER BY display_order ASC
''';

  @override
  Future<Result<List<RoundFixture>>> listRoundFixtures(RoundId roundId) async {
    final result = await _connection.query(
      _selectRoundFixturesSql,
      parameters: {'round_id': roundId.value},
    );
    return switch (result) {
      Err<List<Map<String, dynamic>>>(:final error) => Result.err(error),
      // An empty list is a valid outcome (no fixtures linked yet); the use-case
      // rejects a submission against it — that policy lives in the use-case,
      // not here.
      Ok<List<Map<String, dynamic>>>(:final value) => _mapRoundFixtures(value),
    };
  }

  Result<List<RoundFixture>> _mapRoundFixtures(
    List<Map<String, dynamic>> rows,
  ) {
    final links = <RoundFixture>[];
    for (final row in rows) {
      final roundIdResult = RoundId.tryParse(row['round_id']?.toString());
      final fixtureResult = FixtureRef.tryParse(row['fixture_id']?.toString());
      final displayOrder = row['display_order'];

      if (roundIdResult is Err<RoundId>) {
        return Result.err(
          _corrupt('round_fixtures', 'round_id', roundIdResult.error.message),
        );
      }
      if (fixtureResult is Err<FixtureRef>) {
        return Result.err(
          _corrupt('round_fixtures', 'fixture_id', fixtureResult.error.message),
        );
      }
      if (displayOrder is! int) {
        return Result.err(
          _corrupt('round_fixtures', 'display_order', 'not an integer'),
        );
      }

      links.add(
        RoundFixture.fromStored(
          roundId: (roundIdResult as Ok<RoundId>).value,
          fixture: (fixtureResult as Ok<FixtureRef>).value,
          displayOrder: displayOrder,
        ),
      );
    }
    return Result.ok(List<RoundFixture>.unmodifiable(links));
  }

  // --------------------------------------------------------------------------
  // Constraint resolvers (constraint name → domain invariant)
  // --------------------------------------------------------------------------

  // Names match the constraints declared in migration 0003_prediction.sql.
  static AppError? _onPredictionConstraint(String name) => switch (name) {
    // The physical "predict once" backstop (Axiom 4/6). The submit use-case
    // pivots on this exact code to converge a lost insert race into an
    // amend, so it MUST be reported verbatim.
    'predictions_participant_round_uniq' => const AppError.invariant(
      'prediction.already_submitted',
      'A prediction already exists for this participant and round',
    ),
    'predictions_pkey' => const AppError.invariant(
      'prediction.duplicate_id',
      'A prediction with this id already exists',
    ),
    // FK to a round that does not exist — a precondition the app checks
    // first (findRound); the constraint is the backstop.
    'predictions_round_id_fkey' => const AppError.invariant(
      'prediction.round_not_found',
      'Round not found',
    ),
    'predictions_participant_id_fkey' => const AppError.invariant(
      'prediction.not_a_participant',
      'Participant not found',
    ),
    _ => null,
  };

  static AppError? _onScoreConstraint(String name) => switch (name) {
    // Composite PK (prediction_id, fixture_id): one score per fixture — the
    // domain's no-duplicate-fixture invariant, made physical (Axiom 6).
    'prediction_scores_pkey' => const AppError.invariant(
      'prediction.duplicate_fixture',
      'A prediction may contain at most one score per fixture',
    ),
    'prediction_scores_prediction_id_fkey' => const AppError.invariant(
      'prediction.not_found',
      'Prediction not found',
    ),
    _ => null,
  };

  // --------------------------------------------------------------------------
  // Shared helpers (mirror PostgresCompetitionRepository)
  // --------------------------------------------------------------------------

  /// Collapses a write query result to `Result<void>`, reclassifying a storage
  /// integrity violation to the domain [ErrorKind.invariant] the [onConstraint]
  /// resolver names for the violated constraint.
  Result<void> _asVoid(
    Result<List<Map<String, dynamic>>> result, {
    required AppError? Function(String constraint) onConstraint,
  }) {
    return switch (result) {
      Ok<List<Map<String, dynamic>>>() => const Result.ok(null),
      Err<List<Map<String, dynamic>>>(:final error) => Result.err(
        _reclassify(error, onConstraint: onConstraint),
      ),
    };
  }

  /// Reclassifies a [PostgresConnection]-produced transient error into an
  /// [ErrorKind.invariant] business conflict when its underlying cause is a
  /// storage-integrity violation the application could not pre-empt.
  ///
  /// `PostgresConnection.query` wraps any driver exception as
  /// `AppError.transient(cause: <exception>)`; here we inspect that cause. The
  /// `postgres` 3.5.x driver raises a [ServerException] carrying the SQLSTATE
  /// `code` and (for constraint failures) the `constraintName`; the specialized
  /// subtypes are also `ServerException`s, so matching the base type covers all
  /// of them.
  ///
  /// If the cause is not an integrity violation (or [onConstraint] declines to
  /// map the specific constraint), the original transient error is preserved —
  /// a real infrastructure fault stays retryable.
  AppError _reclassify(
    AppError error, {
    required AppError? Function(String constraint) onConstraint,
  }) {
    final cause = error.cause;
    if (cause is! ServerException) {
      return error;
    }
    final code = cause.code;
    // 23505 unique_violation, 23503 foreign_key_violation,
    // 23514 check_violation (the "no submit after lock" / goal-range checks).
    const integrityCodes = {'23505', '23503', '23514'};
    if (code == null || !integrityCodes.contains(code)) {
      return error;
    }

    final constraint = cause.constraintName;
    if (constraint != null) {
      final mapped = onConstraint(constraint);
      if (mapped != null) {
        return mapped;
      }
    }

    // A recognized integrity class we could not attribute to a named constraint
    // (e.g. the trigger-raised "no submit after lock" check_violation, which
    // carries no constraint name): still a business-rule conflict, reported as
    // the lock rejection the use-case and its callers expect.
    if (code == '23514') {
      return const AppError.invariant(
        'prediction.round_not_open',
        'Predictions can only be written while the round is open',
      );
    }
    return const AppError.invariant(
      'prediction.integrity_violation',
      'The write violated a prediction integrity rule',
    );
  }

  /// A stored row that fails to map indicates data corruption or schema drift —
  /// an infrastructure fault, surfaced as transient rather than blamed on the
  /// caller (mirrors `PostgresCompetitionRepository._corrupt`).
  static AppError _corrupt(String table, String field, String detail) =>
      AppError.transient(
        'prediction.row_corrupt',
        'Stored $table row has invalid $field: $detail',
      );
}
