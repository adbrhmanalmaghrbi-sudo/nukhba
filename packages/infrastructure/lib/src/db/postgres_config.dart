import 'package:shared/shared.dart';

/// Immutable Postgres connection configuration, sourced from environment
/// variables and validated at startup (Security ADR, Section 7: secrets live
/// only in the server env, never in code).
final class PostgresConfig {
  /// Creates a validated Postgres config.
  const PostgresConfig({
    required this.host,
    required this.port,
    required this.database,
    required this.username,
    required this.password,
    required this.requireSsl,
  });

  /// Builds config from an environment map, returning a typed error rather
  /// than throwing if a required value is missing or malformed.
  static Result<PostgresConfig> fromEnv(Map<String, String> env) {
    final host = env['NUKHBA_PG_HOST'];
    final portRaw = env['NUKHBA_PG_PORT'];
    final database = env['NUKHBA_PG_DATABASE'];
    final username = env['NUKHBA_PG_USERNAME'];
    final password = env['NUKHBA_PG_PASSWORD'];
    final sslRaw = env['NUKHBA_PG_SSL'];

    if (host == null || host.isEmpty) {
      return const Result.err(
        AppError.validation('config.pg_host', 'NUKHBA_PG_HOST is required'),
      );
    }
    final port = int.tryParse(portRaw ?? '');
    if (port == null) {
      return const Result.err(
        AppError.validation('config.pg_port', 'NUKHBA_PG_PORT must be an int'),
      );
    }
    if (database == null || database.isEmpty) {
      return const Result.err(
        AppError.validation('config.pg_db', 'NUKHBA_PG_DATABASE is required'),
      );
    }
    if (username == null || username.isEmpty) {
      return const Result.err(
        AppError.validation('config.pg_user', 'NUKHBA_PG_USERNAME is required'),
      );
    }
    if (password == null) {
      return const Result.err(
        AppError.validation('config.pg_pw', 'NUKHBA_PG_PASSWORD is required'),
      );
    }

    return Result.ok(
      PostgresConfig(
        host: host,
        port: port,
        database: database,
        username: username,
        password: password,
        // Default to requiring SSL unless explicitly disabled for local dev.
        requireSsl: (sslRaw ?? 'require') != 'disable',
      ),
    );
  }

  /// Database host.
  final String host;

  /// Database port.
  final int port;

  /// Database name.
  final String database;

  /// Connection username (service-role/privileged on the server).
  final String username;

  /// Connection password. Never logged.
  final String password;

  /// Whether TLS is required (true in all non-local environments).
  final bool requireSsl;
}
