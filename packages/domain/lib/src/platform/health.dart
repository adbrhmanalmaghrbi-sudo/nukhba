/// A domain value describing the platform's liveness.
///
/// This is the minimal domain concept exercised by Milestone 0's
/// end-to-end proof slice. It carries no framework or IO knowledge.
enum HealthStatus {
  /// All checked dependencies are reachable and healthy.
  healthy,

  /// At least one checked dependency is degraded or unreachable.
  unhealthy,
}

/// An immutable snapshot of platform health at a point in time.
final class HealthCheck {
  /// Creates a health snapshot.
  const HealthCheck({required this.status, required this.databaseReachable});

  /// Derives overall health from component signals. Pure and total.
  factory HealthCheck.fromSignals({required bool databaseReachable}) {
    return HealthCheck(
      status: databaseReachable ? HealthStatus.healthy : HealthStatus.unhealthy,
      databaseReachable: databaseReachable,
    );
  }

  /// The overall status, derived from component checks.
  final HealthStatus status;

  /// Whether the primary datastore answered a liveness probe.
  final bool databaseReachable;

  @override
  bool operator ==(Object other) =>
      other is HealthCheck &&
      other.status == status &&
      other.databaseReachable == databaseReachable;

  @override
  int get hashCode => Object.hash(status, databaseReachable);
}
