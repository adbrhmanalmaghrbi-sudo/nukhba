import 'package:infrastructure/src/db/postgres_config.dart';
// `postgres` exports its own `Result` (the query result-row list), which
// collides with our domain-wide `Result<T>` from `shared`. We never reference
// the postgres `Result` type by name here, so hide it to keep `Result`
// unambiguously our `Ok`/`Err` union.
import 'package:postgres/postgres.dart' hide Result;
import 'package:shared/shared.dart';

/// The narrow query surface an adapter needs, satisfied both by the pooled
/// [PostgresConnection] (autocommit — one statement per call) and by a
/// transaction scope handed to [PostgresConnection.runInTransaction] (every
/// statement inside the same transaction, atomically committed or rolled back).
///
/// A repository that must write several statements atomically (e.g. a
/// prediction's parent row plus its child score rows) takes a [DbExecutor] in
/// its write helpers, so the exact same SQL runs either standalone or inside a
/// transaction depending on which executor it is given — without the adapter
/// knowing or caring which. Named parameters are always used (Security ADR §2):
/// no untrusted value is ever concatenated into SQL.
abstract interface class DbExecutor {
  /// Runs a `@named`-parameterized [sql] statement, returning each row as a
  /// column-name map. Never throws — every outcome is a typed [Result]; any
  /// driver failure is surfaced as [ErrorKind.transient].
  Future<Result<List<Map<String, dynamic>>>> query(
    String sql, {
    Map<String, Object?> parameters,
  });
}

/// Owns the lifecycle of the Postgres connection pool.
///
/// A single instance is created at the composition root and shared across
/// requests; the backend is stateless (Platform ADR, Section 1) with all
/// state in Postgres.
///
/// API verified against `postgres` 3.5.x on pub.dev (2026-07-08):
///   * `Pool.withEndpoints(List<Endpoint>, {PoolSettings? settings})`
///   * `PoolSettings({int? maxConnectionCount, SslMode? sslMode, ...})`
///   * `Session.execute(Object query, ...)` returns a `Result`, which is a
///     `List<ResultRow>`, so `.isNotEmpty` is valid.
///
/// This class is intentionally *implementable* (a plain `class`, not `final`):
/// the driver's own `ServerException` has no public constructor, so the only way
/// to exercise an adapter's row-mapping and error-passthrough branches
/// hermetically is to substitute a fake `PostgresConnection` that returns canned
/// [Result]s from [query] (Coding Standards §6: adapters tested against fakes).
/// The `postgres` [Pool] is still private, so no fake can reach the real driver.
class PostgresConnection implements DbExecutor {
  PostgresConnection._(this._pool);

  final Pool<void> _pool;

  /// Opens a connection pool from [config]. Returns a typed error on failure
  /// rather than throwing, so startup can fail cleanly.
  static Future<Result<PostgresConnection>> open(PostgresConfig config) async {
    try {
      final pool = Pool<void>.withEndpoints(
        [
          Endpoint(
            host: config.host,
            port: config.port,
            database: config.database,
            username: config.username,
            password: config.password,
          ),
        ],
        settings: PoolSettings(
          sslMode: config.requireSsl ? SslMode.require : SslMode.disable,
          maxConnectionCount: 8,
        ),
      );
      // Eagerly verify connectivity so startup fails fast on misconfig.
      await pool.execute('SELECT 1');
      return Result.ok(PostgresConnection._(pool));
    } on Object catch (e) {
      return Result.err(
        AppError.transient(
          'db.open_failed',
          'Failed to open Postgres connection pool',
          e,
        ),
      );
    }
  }

  /// Runs a liveness probe. `Ok(true)` when the DB answers `SELECT 1`.
  Future<Result<bool>> ping() async {
    try {
      final result = await _pool.execute('SELECT 1');
      return Result.ok(result.isNotEmpty);
    } on Object catch (e) {
      return Result.err(
        AppError.transient('db.ping_failed', 'Database ping failed', e),
      );
    }
  }

  /// Runs a parameterized query and returns each row as a column-name map.
  ///
  /// Named parameters (`@name`) are always used, so values are bound by the
  /// driver's extended-query protocol and can never be string-concatenated into
  /// SQL — the sole safe path for untrusted input (Security ADR, Section 2).
  /// Any driver failure is surfaced as an [ErrorKind.transient] error rather
  /// than thrown, keeping the adapter total.
  ///
  /// API verified against `postgres` 3.5.x (2026-07-09):
  ///   * `Session.execute(Sql.named(String), {Map<String, Object?>? parameters})`
  ///   * `ResultRow.toColumnMap()` -> `Map<String, dynamic>`.
  Future<Result<List<Map<String, dynamic>>>> query(
    String sql, {
    Map<String, Object?> parameters = const {},
  }) async {
    try {
      final result = await _pool.execute(
        Sql.named(sql),
        parameters: parameters,
      );
      final rows = result
          .map((row) => row.toColumnMap())
          .toList(growable: false);
      return Result.ok(rows);
    } on Object catch (e) {
      return Result.err(
        AppError.transient('db.query_failed', 'Database query failed', e),
      );
    }
  }

  /// Runs [action] inside a single database transaction, committing when it
  /// returns [Ok] and rolling the whole transaction back when it returns [Err].
  ///
  /// Every statement [action] issues against the [DbExecutor] it is handed runs
  /// in the *same* transaction, so a multi-statement write (e.g. a prediction's
  /// parent row plus its child score rows) is all-or-nothing: a failure on any
  /// statement leaves no partial row behind — critical where a half-written
  /// forecast would corrupt the protected competitive record (Axiom 5).
  ///
  /// Implementation: `postgres` 3.5.x [Pool.runTx] commits when its callback
  /// completes normally and rolls back if it throws. Because [action] reports
  /// failure as an [Err] (never an exception — the adapter is total), a private
  /// sentinel is thrown to force the rollback and is then unwrapped back into
  /// the original [Err], so no exception escapes this method. A genuinely
  /// unexpected driver throw is caught and surfaced as [ErrorKind.transient].
  ///
  /// API verified against `postgres` 3.5.x (2026-07-11):
  ///   * `Pool.runTx<R>(Future<R> Function(TxSession), {TransactionSettings?})`
  ///   * `TxSession` implements `Session` → `execute(Sql.named(...), ...)`.
  Future<Result<T>> runInTransaction<T>(
    Future<Result<T>> Function(DbExecutor tx) action,
  ) async {
    try {
      final value = await _pool.runTx((session) async {
        final result = await action(_TxExecutor(session));
        return switch (result) {
          Ok<T>(:final value) => value,
          // Force a rollback by throwing; carry the Err out to rethrow-unwrap.
          Err<T>(:final error) => throw _RollbackSignal(error),
        };
      });
      return Result.ok(value);
    } on _RollbackSignal catch (signal) {
      // The transaction rolled back cleanly; return the domain error verbatim.
      return Result.err(signal.error);
    } on Object catch (e) {
      return Result.err(
        AppError.transient('db.tx_failed', 'Database transaction failed', e),
      );
    }
  }

  /// Closes the pool. Called on graceful shutdown.
  Future<void> close() => _pool.close();
}

/// Thrown inside [PostgresConnection.runInTransaction] to force `Pool.runTx` to
/// roll back when the caller's action returned an [Err]; caught and unwrapped
/// so no exception ever escapes the total adapter surface.
final class _RollbackSignal implements Exception {
  const _RollbackSignal(this.error);

  final AppError error;
}

/// A [DbExecutor] backed by a `postgres` [TxSession], so a repository's write
/// helpers issue their statements inside the enclosing transaction. Mirrors
/// [PostgresConnection.query]'s contract (named parameters, total `Result`
/// return, column-name-map rows), differing only in that the statement runs in
/// the transaction rather than autocommit.
final class _TxExecutor implements DbExecutor {
  const _TxExecutor(this._session);

  final Session _session;

  @override
  Future<Result<List<Map<String, dynamic>>>> query(
    String sql, {
    Map<String, Object?> parameters = const {},
  }) async {
    try {
      final result = await _session.execute(
        Sql.named(sql),
        parameters: parameters,
      );
      final rows = result
          .map((row) => row.toColumnMap())
          .toList(growable: false);
      return Result.ok(rows);
    } on Object catch (e) {
      // Surface as transient; runInTransaction converts a returned Err into a
      // rollback. Re-raising the underlying driver exception is avoided so the
      // integrity-violation `cause` (ServerException) still reaches the adapter
      // reclassifier via the returned Err — see PostgresPredictionRepository.
      return Result.err(
        AppError.transient('db.query_failed', 'Database query failed', e),
      );
    }
  }
}
