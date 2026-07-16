import 'package:contracts/contracts.dart';
import 'package:test/test.dart';

void main() {
  group('HealthResponseDto', () {
    test('round-trips through JSON', () {
      const dto = HealthResponseDto(status: 'healthy', databaseReachable: true);
      final decoded = HealthResponseDto.fromJson(dto.toJson());
      expect(decoded, dto);
      expect(decoded.schemaVersion, HealthResponseDto.currentSchemaVersion);
    });

    test('defaults schema_version to 1 when absent (back-compat)', () {
      final decoded = HealthResponseDto.fromJson(const {
        'status': 'unhealthy',
        'database_reachable': false,
      });
      expect(decoded.schemaVersion, 1);
      expect(decoded.status, 'unhealthy');
    });
  });
}
