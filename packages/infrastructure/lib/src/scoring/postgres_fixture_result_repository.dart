import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:infrastructure/src/db/postgres_connection.dart';
// `postgres` exports its own `Result`; we only need its exception hierarchy
// here (to read the SQLSTATE `code`/`constraintName` off a `ServerException`),
// so hide `Result` to keep `Result<T>` unambiguously our `shared` union.
import 'package:postgres/postgres.dart' hide Result;
import 'package:shared/shared.dart';

/// Postgres-backed [FixtureResultRepository] over the `scoring.fixture_results`
/// table (Database ADR; migration `0004_scoring.sql`).
///
/// This is the storage side of the Axiom-3 football seam (Next-Task decision
/// 2026-07-11, option (a)): the actual scoreline is ingested by an admin command
/// and read back at scoring time, keyed by fixture id only — the row carries no
/// competition/round reference (Axiom 3), so the same result feeds every round
/// the fixture belongs to.
///
/// The adapter is *total* (Application ADR §2): it never throws — every outcome
/// is a typed [Result]. It speaks only in the domain [FixtureResult] value and
/// typed [FixtureRef]; SQL and rows never leak past this boundary.
///
/// Error mapping (the port's general contract):
/// * A check-constraint rejection (`23514`, the goal-range backstop mirroring
///   `FixtureResult.maxGoals`) is an [ErrorKind.invariant] conflict.
/// * A genuinely transient/infrastructure failure stays [ErrorKind.transient],
///   exactly as [PostgresConnection.query] classified it.
///
/// All queries bind values through `@named` parameters (Security ADR §2): no
/// untrusted value is ever concatenated into SQL.
final class PostgresFixtureResultRepository implements FixtureResultRepository {
  /// Creates the repository over an open [PostgresConnection].
  const PostgresFixtureResultRepository(this._connection);

  final PostgresConnection _connection;

  // --------------------------------------------------------------------------
  // upsert — admin ingestion (idempotent correction per fixture)
  // --------------------------------------------------------------------------

  // ON CONFLICT (fixture_id) refreshes the scoreline in place so an admin can
  // correct a mistyped result before scoring, and a retried ingestion converges
  // on the same stored row. `recorded_at` is refreshed to the ingestion instant.
  static const String _upsertSql = '''
INSERT INTO scoring.fixture_results
  (fixture_id, home_goals, away_goals, recorded_at)
VALUES (@fixture_id, @home_goals, @away_goals, @recorded_at)
ON CONFLICT (fixture_id) DO UPDATE SET
  home_goals  = EXCLUDED.home_goals,
  away_goals  = EXCLUDED.away_goals,
  recorded_at = EXCLUDED.recorded_at
''';

  @override
  Future<Result<void>> upsert(FixtureResult result, DateTime recordedAt) async {
    final inserted = await _connection.query(
      _upsertSql,
      parameters: {
        'fixture_id': result.fixture.value,
        'home_goals': result.homeGoals,
        'away_goals': result.awayGoals,
        'recorded_at': recordedAt.toUtc().toIso8601String(),
      },
    );
    return switch (inserted) {
      Ok<List<Map<String, dynamic>>>() => const Result.ok(null),
      Err<List<Map<String, dynamic>>>(:final error) => Result.err(
        _reclassify(error),
      ),
    };
  }

  // --------------------------------------------------------------------------
  // findByFixture — single-fixture read (Ok(null) when none recorded)
  // --------------------------------------------------------------------------

  static const String _selectByFixtureSql = '''
SELECT fixture_id, home_goals, away_goals
FROM scoring.fixture_results
WHERE fixture_id = @fixture_id
''';

  @override
  Future<Result<FixtureResult?>> findByFixture(FixtureRef fixture) async {
    final result = await _connection.query(
      _selectByFixtureSql,
      parameters: {'fixture_id': fixture.value},
    );
    return switch (result) {
      Err<List<Map<String, dynamic>>>(:final error) => Result.err(error),
      Ok<List<Map<String, dynamic>>>(:final value) =>
        value.isEmpty ? const Result.ok(null) : _mapOne(value.first),
    };
  }

  // --------------------------------------------------------------------------
  // findByFixtures — batch read; absent fixtures are simply omitted
  // --------------------------------------------------------------------------

  // ANY(@fixture_ids) binds the id list as a single array parameter (no dynamic
  // SQL, no per-id concatenation — Security ADR §2). A fixture with no recorded
  // result is naturally absent from the result set; the scoring use-case detects
  // the gap by comparing counts, never by a fabricated zero.
  static const String _selectByFixturesSql = '''
SELECT fixture_id, home_goals, away_goals
FROM scoring.fixture_results
WHERE fixture_id = ANY(@fixture_ids)
''';

  @override
  Future<Result<List<FixtureResult>>> findByFixtures(
    List<FixtureRef> fixtures,
  ) async {
    if (fixtures.isEmpty) {
      return const Result.ok(<FixtureResult>[]);
    }
    final result = await _connection.query(
      _selectByFixturesSql,
      parameters: {
        'fixture_ids': [for (final f in fixtures) f.value],
      },
    );
    return switch (result) {
      Err<List<Map<String, dynamic>>>(:final error) => Result.err(error),
      Ok<List<Map<String, dynamic>>>(:final value) => _mapMany(value),
    };
  }

  // --------------------------------------------------------------------------
  // Row mapping
  // --------------------------------------------------------------------------

  Result<FixtureResult?> _mapOne(Map<String, dynamic> row) {
    final mapped = _mapRow(row);
    return switch (mapped) {
      Ok<FixtureResult>(:final value) => Result.ok(value),
      Err<FixtureResult>(:final error) => Result.err(error),
    };
  }

  Result<List<FixtureResult>> _mapMany(List<Map<String, dynamic>> rows) {
    final results = <FixtureResult>[];
    for (final row in rows) {
      final mapped = _mapRow(row);
      if (mapped is Err<FixtureResult>) {
        return Result.err(mapped.error);
      }
      results.add((mapped as Ok<FixtureResult>).value);
    }
    return Result.ok(List<FixtureResult>.unmodifiable(results));
  }

  Result<FixtureResult> _mapRow(Map<String, dynamic> row) {
    final fixtureResult = FixtureRef.tryParse(row['fixture_id']?.toString());
    final homeGoals = row['home_goals'];
    final awayGoals = row['away_goals'];

    if (fixtureResult is Err<FixtureRef>) {
      return Result.err(
        _corrupt('fixture_results', 'fixture_id', fixtureResult.error.message),
      );
    }
    if (homeGoals is! int) {
      return Result.err(
        _corrupt('fixture_results', 'home_goals', 'not an integer'),
      );
    }
    if (awayGoals is! int) {
      return Result.err(
        _corrupt('fixture_results', 'away_goals', 'not an integer'),
      );
    }
    return Result.ok(
      FixtureResult.fromStored(
        fixture: (fixtureResult as Ok<FixtureRef>).value,
        homeGoals: homeGoals,
        awayGoals: awayGoals,
      ),
    );
  }

  // --------------------------------------------------------------------------
  // Error reclassification (mirrors the prediction/competition adapters)
  // --------------------------------------------------------------------------

  AppError _reclassify(AppError error) {
    final cause = error.cause;
    if (cause is! ServerException) {
      return error;
    }
    // 23514 check_violation — the goal-range backstop (Axiom 6) mirroring
    // FixtureResult.maxGoals. Anything else stays as classified.
    if (cause.code == '23514') {
      return const AppError.invariant(
        'scoring.result_integrity_violation',
        'The recorded result violated a fixture-result integrity rule',
      );
    }
    return error;
  }

  static AppError _corrupt(String table, String field, String detail) =>
      AppError.transient(
        'scoring.row_corrupt',
        'Stored $table row has invalid $field: $detail',
      );
}
