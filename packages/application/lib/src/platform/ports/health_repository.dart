import 'package:shared/shared.dart';

/// Port for probing datastore liveness.
///
/// Implemented in Infrastructure (Repository pattern — Application ADR,
/// Section 9). The application depends on this interface, never on a concrete
/// database.
abstract interface class HealthRepository {
  /// Returns `Ok(true)` if the datastore answered a liveness probe,
  /// `Ok(false)` if it responded-but-unhealthy, or `Err` on transient failure.
  Future<Result<bool>> pingDatabase();
}
