import 'package:domain/domain.dart';
import 'package:test/test.dart';

void main() {
  group('HealthCheck.fromSignals', () {
    test('is healthy when database reachable', () {
      final check = HealthCheck.fromSignals(databaseReachable: true);
      expect(check.status, HealthStatus.healthy);
      expect(check.databaseReachable, isTrue);
    });

    test('is unhealthy when database unreachable', () {
      final check = HealthCheck.fromSignals(databaseReachable: false);
      expect(check.status, HealthStatus.unhealthy);
      expect(check.databaseReachable, isFalse);
    });
  });
}
