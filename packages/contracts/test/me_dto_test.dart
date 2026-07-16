import 'package:contracts/contracts.dart';
import 'package:test/test.dart';

void main() {
  group('AuthenticatedUserDto', () {
    test('round-trips through JSON with all fields', () {
      const dto = AuthenticatedUserDto(
        userId: '11111111-2222-3333-4444-555555555555',
        role: 'admin',
        status: 'active',
        email: 'a@example.com',
      );
      final decoded = AuthenticatedUserDto.fromJson(dto.toJson());
      expect(decoded, dto);
    });

    test('round-trips with a null email', () {
      const dto = AuthenticatedUserDto(
        userId: '11111111-2222-3333-4444-555555555555',
        role: 'user',
        status: 'suspended',
      );
      final decoded = AuthenticatedUserDto.fromJson(dto.toJson());
      expect(decoded, dto);
      expect(decoded.email, isNull);
    });
  });

  group('MeResponseDto', () {
    const user = AuthenticatedUserDto(
      userId: '11111111-2222-3333-4444-555555555555',
      role: 'user',
      status: 'active',
      email: 'a@example.com',
    );

    test('round-trips through JSON', () {
      const dto = MeResponseDto(user: user);
      final decoded = MeResponseDto.fromJson(dto.toJson());
      expect(decoded, dto);
      expect(decoded.schemaVersion, MeResponseDto.currentSchemaVersion);
    });

    test('defaults schema_version to 1 when absent (back-compat)', () {
      final decoded = MeResponseDto.fromJson({'user': user.toJson()});
      expect(decoded.schemaVersion, 1);
      expect(decoded.user, user);
    });

    test('serializes with a nested user object under `user`', () {
      const dto = MeResponseDto(user: user);
      final json = dto.toJson();
      expect(json['schema_version'], 1);
      expect(json['user'], isA<Map<String, Object?>>());
      expect((json['user']! as Map)['role'], 'user');
    });
  });
}
