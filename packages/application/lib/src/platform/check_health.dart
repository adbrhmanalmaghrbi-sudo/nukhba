import 'package:application/src/platform/ports/health_repository.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// Use-case: derive the platform's [HealthCheck] from component probes.
///
/// This is Milestone 0's trivial end-to-end use-case, flowing
/// controller -> use-case -> port -> adapter -> Postgres (Roadmap ADR,
/// Milestone 0 exit criterion).
final class CheckHealth {
  /// Creates the use-case with its required [HealthRepository] port.
  const CheckHealth(this._healthRepository);

  final HealthRepository _healthRepository;

  /// Executes the health check. Never throws; returns a typed [Result].
  Future<Result<HealthCheck>> call() async {
    final ping = await _healthRepository.pingDatabase();
    return switch (ping) {
      Ok<bool>(:final value) => Result.ok(
        HealthCheck.fromSignals(databaseReachable: value),
      ),
      // A transient DB failure still yields a valid (unhealthy) HealthCheck,
      // so the health endpoint can report degradation rather than error out.
      Err<bool>() => Result.ok(
        HealthCheck.fromSignals(databaseReachable: false),
      ),
    };
  }
}
