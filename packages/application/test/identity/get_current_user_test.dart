import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

const _uuid = '11111111-2222-3333-4444-555555555555';

/// In-memory [UserDirectory] fake: returns a scripted result and records the
/// principal it was asked to resolve.
final class _FakeUserDirectory implements UserDirectory {
  _FakeUserDirectory(this._response);

  final Result<User> _response;
  AuthenticatedUser? lastPrincipal;

  @override
  Future<Result<User>> ensureUser(AuthenticatedUser principal) async {
    lastPrincipal = principal;
    return _response;
  }
}

AuthenticatedUser _principal() => AuthenticatedUser(
  userId: const UserId(_uuid),
  role: PlatformRole.user,
  email: 'a@example.com',
);

void main() {
  group('GetCurrentUser', () {
    test('resolves the canonical user via the directory', () async {
      final canonical = User(
        id: const UserId(_uuid),
        email: 'a@example.com',
        role: PlatformRole.admin, // platform-owned, may differ from token role
        status: UserStatus.active,
      );
      final directory = _FakeUserDirectory(Result.ok(canonical));
      final useCase = GetCurrentUser(directory);

      final result = await useCase(_principal());

      expect((result as Ok<User>).value, canonical);
      // The directory is queried with the exact verified principal.
      expect(directory.lastPrincipal!.userId.value, _uuid);
    });

    test('propagates a transient directory failure for retry', () async {
      final directory = _FakeUserDirectory(
        const Result.err(
          AppError.transient('identity.upsert_no_row', 'no row'),
        ),
      );
      final useCase = GetCurrentUser(directory);

      final result = await useCase(_principal());

      expect((result as Err<User>).error.kind, ErrorKind.transient);
    });
  });
}
