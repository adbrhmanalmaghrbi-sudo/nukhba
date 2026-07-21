/// Unit tests for [SessionController] — the four scenarios §4 mandates:
/// successful sign-in, bad-credentials sign-in, lost connection, and restoring
/// a saved session at app open. Each drives the real controller over the
/// [buildAuthHarness] wiring (MockClient transport + in-memory token store),
/// asserting both the resulting [SessionState] and the token-store side effect.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mobile/features/auth/session_controller.dart';
import 'package:mobile/features/auth/session_state.dart';
import 'package:shared/shared.dart';

import '../../support/auth_harness.dart';

void main() {
  group('SessionController.build (boot-time restore)', () {
    test(
      'no persisted token -> SessionUnauthenticated, no network call',
      () async {
        final harness = buildAuthHarness(
          (_) async => okMe(sampleUser),
          // no seedToken
        );
        addTearDown(harness.dispose);

        final state = await harness.container.read(
          sessionControllerProvider.future,
        );

        expect(state, const SessionUnauthenticated());
        expect(
          harness.captured,
          isEmpty,
          reason: 'must not probe /me when there is no token',
        );
      },
    );

    test(
      'valid persisted token -> SessionAuthenticated with the /me principal',
      () async {
        final harness = buildAuthHarness(
          (_) async => okMe(sampleUser),
          seedToken: 'saved-jwt',
        );
        addTearDown(harness.dispose);

        final state = await harness.container.read(
          sessionControllerProvider.future,
        );

        expect(state, const SessionAuthenticated(sampleUser));
        // The restore probe carried the persisted bearer token.
        expect(
          harness.captured.single.request.headers['authorization'],
          'Bearer saved-jwt',
        );
        // Still persisted (a good token is kept).
        expect(await harness.store.read(), 'saved-jwt');
      },
    );

    test('persisted-but-expired token -> SessionFailed(authorization) and the '
        'stale token is cleared', () async {
      final harness = buildAuthHarness(
        (_) async => errorEnvelope(401, 'auth.token_expired', 'Token expired.'),
        seedToken: 'stale-jwt',
      );
      addTearDown(harness.dispose);

      final state = await harness.container.read(
        sessionControllerProvider.future,
      );

      expect(state, isA<SessionFailed>());
      expect((state as SessionFailed).error.kind, ErrorKind.authorization);
      expect(
        await harness.store.read(),
        isNull,
        reason: 'a definitively-rejected token must not linger on disk',
      );
    });
  });

  group('SessionController.signIn', () {
    test(
      'success: persists the token and yields SessionAuthenticated',
      () async {
        final harness = buildAuthHarness((_) async => okMe(sampleUser));
        addTearDown(harness.dispose);

        // Resolve the initial (unauthenticated) build first.
        await harness.container.read(sessionControllerProvider.future);

        await harness.container
            .read(sessionControllerProvider.notifier)
            .signIn('fresh-jwt');

        final state = harness.container.read(sessionControllerProvider).value;
        expect(state, const SessionAuthenticated(sampleUser));
        expect(
          await harness.store.read(),
          'fresh-jwt',
          reason: 'a validated token is persisted for next launch',
        );
        // The /me probe carried the token we just signed in with.
        expect(
          harness.captured.last.request.headers['authorization'],
          'Bearer fresh-jwt',
        );
      },
    );

    test('bad credentials (401): SessionFailed(authorization) and no token '
        'persisted', () async {
      final harness = buildAuthHarness(
        (_) async => errorEnvelope(401, 'auth.token_invalid', 'Invalid token.'),
      );
      addTearDown(harness.dispose);
      await harness.container.read(sessionControllerProvider.future);

      await harness.container
          .read(sessionControllerProvider.notifier)
          .signIn('bogus-jwt');

      final state = harness.container.read(sessionControllerProvider).value;
      expect(state, isA<SessionFailed>());
      final error = (state as SessionFailed).error;
      expect(error.kind, ErrorKind.authorization);
      expect(error.code, 'auth.token_invalid');
      expect(await harness.store.read(), isNull);
    });

    test('lost connection (transport throws): SessionFailed(transient, '
        'retryable) and the token is KEPT for retry', () async {
      final harness = buildAuthHarness(
        (_) async => throw Exception('socket reset'),
      );
      addTearDown(harness.dispose);
      await harness.container.read(sessionControllerProvider.future);

      await harness.container
          .read(sessionControllerProvider.notifier)
          .signIn('good-but-offline-jwt');

      final state = harness.container.read(sessionControllerProvider).value;
      expect(state, isA<SessionFailed>());
      final error = (state as SessionFailed).error;
      expect(error.kind, ErrorKind.transient);
      expect(error.isRetryable, isTrue);
      expect(
        await harness.store.read(),
        'good-but-offline-jwt',
        reason: 'a transient failure is not the token\'s fault; keep it',
      );
    });

    test(
      'empty token: SessionFailed(validation) without touching the network',
      () async {
        final harness = buildAuthHarness((_) async => okMe(sampleUser));
        addTearDown(harness.dispose);
        await harness.container.read(sessionControllerProvider.future);

        await harness.container
            .read(sessionControllerProvider.notifier)
            .signIn('   ');

        final state = harness.container.read(sessionControllerProvider).value;
        expect(state, isA<SessionFailed>());
        expect((state as SessionFailed).error.kind, ErrorKind.validation);
        expect(harness.captured, isEmpty);
      },
    );
  });

  group('SessionController.signOut', () {
    test('clears the token and returns to SessionUnauthenticated', () async {
      final harness = buildAuthHarness(
        (_) async => okMe(sampleUser),
        seedToken: 'saved-jwt',
      );
      addTearDown(harness.dispose);
      await harness.container.read(sessionControllerProvider.future);

      await harness.container
          .read(sessionControllerProvider.notifier)
          .signOut();

      expect(
        harness.container.read(sessionControllerProvider).value,
        const SessionUnauthenticated(),
      );
      expect(await harness.store.read(), isNull);
    });
  });

  group('SessionController.retry (after a transient failure)', () {
    test(
      're-validates the kept token and can succeed the second time',
      () async {
        var attempt = 0;
        final harness = buildAuthHarness((_) async {
          attempt++;
          if (attempt == 1) throw Exception('offline');
          return okMe(sampleUser);
        }, seedToken: 'kept-jwt');
        addTearDown(harness.dispose);

        // First (boot) attempt fails transiently but keeps the token.
        final first = await harness.container.read(
          sessionControllerProvider.future,
        );
        expect(first, isA<SessionFailed>());
        expect((first as SessionFailed).error.kind, ErrorKind.transient);
        expect(await harness.store.read(), 'kept-jwt');

        // Retry: the connection is back, /me succeeds.
        await harness.container
            .read(sessionControllerProvider.notifier)
            .retry();

        expect(
          harness.container.read(sessionControllerProvider).value,
          const SessionAuthenticated(sampleUser),
        );
      },
    );
  });

  group('malformed /me body', () {
    test(
      '200 with wrong shape -> SessionFailed(validation, malformed)',
      () async {
        final harness = buildAuthHarness(
          (_) async => http.Response(
            jsonEncode({'unexpected': 'shape'}),
            200,
            headers: const {'content-type': 'application/json'},
          ),
          seedToken: 'jwt',
        );
        addTearDown(harness.dispose);

        final state = await harness.container.read(
          sessionControllerProvider.future,
        );

        expect(state, isA<SessionFailed>());
        expect((state as SessionFailed).error.kind, ErrorKind.validation);
      },
    );
  });
}
