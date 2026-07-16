import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

/// A canonical, well-formed UUID reused across cases.
const _uuid = '11111111-2222-3333-4444-555555555555';

void main() {
  group('UserId.tryParse', () {
    test('accepts a canonical UUID', () {
      final result = UserId.tryParse(_uuid);
      expect(result.isOk, isTrue);
      expect((result as Ok<UserId>).value.value, _uuid);
    });

    test('rejects null with a validation error', () {
      final result = UserId.tryParse(null);
      expect(result, isA<Err<UserId>>());
      expect((result as Err<UserId>).error.kind, ErrorKind.validation);
      expect(result.error.code, 'identity.user_id_empty');
    });

    test('rejects an empty string', () {
      final result = UserId.tryParse('');
      expect((result as Err<UserId>).error.code, 'identity.user_id_empty');
    });

    test('rejects a non-UUID string', () {
      final result = UserId.tryParse('not-a-uuid');
      expect((result as Err<UserId>).error.code, 'identity.user_id_malformed');
    });

    test('two ids with the same value are equal', () {
      expect(const UserId(_uuid), const UserId(_uuid));
    });
  });

  group('PlatformRole.tryParse', () {
    test('parses each known role', () {
      expect(
        (PlatformRole.tryParse('user') as Ok<PlatformRole>).value,
        PlatformRole.user,
      );
      expect(
        (PlatformRole.tryParse('admin') as Ok<PlatformRole>).value,
        PlatformRole.admin,
      );
      expect(
        (PlatformRole.tryParse('service') as Ok<PlatformRole>).value,
        PlatformRole.service,
      );
    });

    test('rejects an unknown role with a validation error', () {
      final result = PlatformRole.tryParse('root');
      expect((result as Err<PlatformRole>).error.kind, ErrorKind.validation);
      expect(result.error.code, 'identity.role_unknown');
    });

    test('rejects a null role (no implicit default)', () {
      expect(PlatformRole.tryParse(null), isA<Err<PlatformRole>>());
    });
  });

  group('PlatformRole.fromClaimOrUser', () {
    test('defaults to user when the claim is null or blank', () {
      expect(
        (PlatformRole.fromClaimOrUser(null) as Ok<PlatformRole>).value,
        PlatformRole.user,
      );
      expect(
        (PlatformRole.fromClaimOrUser('') as Ok<PlatformRole>).value,
        PlatformRole.user,
      );
    });

    test('still rejects a present-but-unknown claim', () {
      expect(PlatformRole.fromClaimOrUser('root'), isA<Err<PlatformRole>>());
    });
  });

  group('AuthenticatedUser.hasRole (role hierarchy)', () {
    AuthenticatedUser principal(PlatformRole role) =>
        AuthenticatedUser(userId: const UserId(_uuid), role: role);

    test('service satisfies every role requirement', () {
      final service = principal(PlatformRole.service);
      expect(service.hasRole(PlatformRole.user), isTrue);
      expect(service.hasRole(PlatformRole.admin), isTrue);
      expect(service.hasRole(PlatformRole.service), isTrue);
    });

    test('admin satisfies a user requirement (superset authority)', () {
      final admin = principal(PlatformRole.admin);
      expect(admin.hasRole(PlatformRole.user), isTrue);
      expect(admin.hasRole(PlatformRole.admin), isTrue);
    });

    test('admin does NOT satisfy a service requirement', () {
      expect(
        principal(PlatformRole.admin).hasRole(PlatformRole.service),
        isFalse,
      );
    });

    test('user satisfies only a user requirement', () {
      final user = principal(PlatformRole.user);
      expect(user.hasRole(PlatformRole.user), isTrue);
      expect(user.hasRole(PlatformRole.admin), isFalse);
      expect(user.hasRole(PlatformRole.service), isFalse);
    });

    test('value equality ignores nothing it carries', () {
      final a = AuthenticatedUser(
        userId: const UserId(_uuid),
        role: PlatformRole.user,
        email: 'a@example.com',
      );
      final b = AuthenticatedUser(
        userId: const UserId(_uuid),
        role: PlatformRole.user,
        email: 'a@example.com',
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });

  group('User.canAct', () {
    User user(PlatformRole role, UserStatus status) =>
        User(id: const UserId(_uuid), email: null, role: role, status: status);

    test('active human user may act', () {
      expect(user(PlatformRole.user, UserStatus.active).canAct, isTrue);
    });

    test('suspended human user may NOT act', () {
      expect(user(PlatformRole.user, UserStatus.suspended).canAct, isFalse);
    });

    test('service principal may act even if status is suspended', () {
      expect(user(PlatformRole.service, UserStatus.suspended).canAct, isTrue);
    });

    test('copyWith replaces only the given fields', () {
      final original = user(PlatformRole.user, UserStatus.active);
      final updated = original.copyWith(status: UserStatus.suspended);
      expect(updated.status, UserStatus.suspended);
      expect(updated.role, original.role);
      expect(updated.id, original.id);
    });
  });

  group('User.suspend', () {
    User user(PlatformRole role, UserStatus status) => User(
      id: const UserId(_uuid),
      email: 'human@example.com',
      role: role,
      status: status,
    );

    test('suspends an active human user (active -> suspended)', () {
      final original = user(PlatformRole.user, UserStatus.active);
      final result = original.suspend();
      expect(result.isOk, isTrue);
      final suspended = (result as Ok<User>).value;
      expect(suspended.status, UserStatus.suspended);
      // Only status changes; identity/email/role preserved.
      expect(suspended.id, original.id);
      expect(suspended.email, original.email);
      expect(suspended.role, original.role);
      // The original value is untouched (immutability).
      expect(original.status, UserStatus.active);
    });

    test('suspends an admin human user', () {
      final result = user(PlatformRole.admin, UserStatus.active).suspend();
      expect((result as Ok<User>).value.status, UserStatus.suspended);
    });

    test('is idempotent: suspending an already-suspended user returns an '
        'equal value, not an error', () {
      final already = user(PlatformRole.user, UserStatus.suspended);
      final result = already.suspend();
      expect(result.isOk, isTrue);
      expect((result as Ok<User>).value, already);
    });

    test('refuses to suspend a service principal (invariant)', () {
      final result = user(PlatformRole.service, UserStatus.active).suspend();
      expect(result, isA<Err<User>>());
      final error = (result as Err<User>).error;
      expect(error.kind, ErrorKind.invariant);
      expect(error.code, 'identity.cannot_suspend_service');
    });

    test('refuses a service principal even when already suspended '
        '(service check precedes the idempotency short-circuit)', () {
      final result = user(PlatformRole.service, UserStatus.suspended).suspend();
      expect(result, isA<Err<User>>());
      expect(
        (result as Err<User>).error.code,
        'identity.cannot_suspend_service',
      );
    });
  });

  group('User.reinstate', () {
    User user(PlatformRole role, UserStatus status) => User(
      id: const UserId(_uuid),
      email: 'human@example.com',
      role: role,
      status: status,
    );

    test('reinstates a suspended user (suspended -> active)', () {
      final original = user(PlatformRole.user, UserStatus.suspended);
      final result = original.reinstate();
      expect(result.isOk, isTrue);
      final active = (result as Ok<User>).value;
      expect(active.status, UserStatus.active);
      expect(active.id, original.id);
      expect(active.email, original.email);
      expect(active.role, original.role);
      // The original value is untouched (immutability).
      expect(original.status, UserStatus.suspended);
    });

    test('is idempotent: reinstating an already-active user returns an '
        'equal value, not an error', () {
      final already = user(PlatformRole.user, UserStatus.active);
      final result = already.reinstate();
      expect(result.isOk, isTrue);
      expect((result as Ok<User>).value, already);
    });

    test('reinstate does NOT gate on role (a suspended admin can be '
        'reinstated)', () {
      final result = user(PlatformRole.admin, UserStatus.suspended).reinstate();
      expect((result as Ok<User>).value.status, UserStatus.active);
    });
  });

  group('User suspend/reinstate round trip', () {
    User activeUser() => const User(
      id: UserId(_uuid),
      email: 'human@example.com',
      role: PlatformRole.user,
      status: UserStatus.active,
    );

    test(
      'active -> suspend -> reinstate returns an equal value to the start',
      () {
        final start = activeUser();
        final suspended = (start.suspend() as Ok<User>).value;
        expect(suspended.status, UserStatus.suspended);
        final reinstated = (suspended.reinstate() as Ok<User>).value;
        expect(reinstated.status, UserStatus.active);
        expect(reinstated, start);
      },
    );

    test('a suspended user cannot act; reinstating restores canAct', () {
      final suspended = (activeUser().suspend() as Ok<User>).value;
      expect(suspended.canAct, isFalse);
      final reinstated = (suspended.reinstate() as Ok<User>).value;
      expect(reinstated.canAct, isTrue);
    });
  });
}
