import 'package:application/application.dart';
import 'package:infrastructure/src/db/postgres_connection.dart';
import 'package:shared/shared.dart';

/// Postgres-backed implementation of [HealthRepository].
///
/// This adapter is the outermost edge of the health slice: it translates a
/// database probe into a domain-friendly [Result] (Application ADR, Section 9).
final class PostgresHealthRepository implements HealthRepository {
  /// Creates the repository over an open [PostgresConnection].
  const PostgresHealthRepository(this._connection);

  final PostgresConnection _connection;

  @override
  Future<Result<bool>> pingDatabase() => _connection.ping();
}
