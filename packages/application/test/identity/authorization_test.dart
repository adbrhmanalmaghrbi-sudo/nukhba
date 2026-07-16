import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

const _uuid = '11111111-2222-3333-4444-555555555555';

AuthenticatedUser _principal(PlatformRole role) =>
    AuthenticatedUser(userId: const UserId(_uuid), role: role);

void main() {
  group('Authorization.requireRole', () {
    test('returns Ok(principal) when authority is sufficient', () {
      final principal = _principal(PlatformRole.admin);
      final result = Authorization.requireRole(principal, PlatformRole.user);
      expect((result as Ok<AuthenticatedUser>).value, principal);
    });

    test('returns Ok for an exact role match', () {
      final principal = _principal(PlatformRole.admin);
      final result = Authorization.requireRole(principal, PlatformRole.admin);
      expect(result.isOk, isTrue);
    });

    test('service satisfies any requirement', () {
      final result = Authorization.requireRole(
        _principal(PlatformRole.service),
        PlatformRole.admin,
      );
      expect(result.isOk, isTrue);
    });

    test('returns an authorization error when authority is insufficient', () {
      final result = Authorization.requireRole(
        _principal(PlatformRole.user),
        PlatformRole.admin,
      );
      expect(
        (result as Err<AuthenticatedUser>).error.kind,
        ErrorKind.authorization,
      );
      expect(result.error.code, 'auth.insufficient_role');
    });
  });
}
