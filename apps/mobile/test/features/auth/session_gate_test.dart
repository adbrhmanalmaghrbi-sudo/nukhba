/// Widget tests for the Auth UI wired through the real [SessionGate] +
/// [SignInScreen] + [AccountScreen], over the [buildAuthHarness] fakes.
///
/// Covers the user-visible outcomes of the four §4 scenarios: a saved session
/// restores straight to the account screen; a signed-out user sees the sign-in
/// form, signs in successfully and lands on the account screen; bad credentials
/// keep them on the form with an error banner; and a lost connection shows the
/// (retryable) transient message.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/features/auth/session_gate.dart';

import '../../support/auth_harness.dart';

Widget _appUnder(AuthHarness harness) => ProviderScope(
  overrides: harness.overrides,
  child: const MaterialApp(home: SessionGate()),
);

void main() {
  testWidgets('restored valid session lands on the account screen', (
    tester,
  ) async {
    final harness = buildAuthHarness(
      (_) async => okMe(sampleUser),
      seedToken: 'saved-jwt',
    );
    addTearDown(harness.dispose);

    await tester.pumpWidget(_appUnder(harness));
    // First frame: boot restore in flight -> splash.
    expect(find.byKey(const Key('session.splash')), findsOneWidget);

    await tester.pumpAndSettle();

    expect(find.byKey(const Key('account.title')), findsOneWidget);
    expect(find.byKey(const Key('account.userId')), findsOneWidget);
    expect(find.text('u-1'), findsOneWidget);
  });

  testWidgets(
    'no token -> sign-in form; successful sign-in -> account screen',
    (tester) async {
      final harness = buildAuthHarness((_) async => okMe(sampleUser));
      addTearDown(harness.dispose);

      await tester.pumpWidget(_appUnder(harness));
      await tester.pumpAndSettle();

      // Signed out: the form is shown.
      expect(find.byKey(const Key('signIn.title')), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('signIn.tokenField')),
        'fresh-jwt',
      );
      await tester.tap(find.byKey(const Key('signIn.submit')));
      await tester.pumpAndSettle();

      // Landed on the account screen with the /me principal.
      expect(find.byKey(const Key('account.title')), findsOneWidget);
      expect(find.text('u-1'), findsOneWidget);
      expect(await harness.store.read(), 'fresh-jwt');
    },
  );

  testWidgets('bad credentials keep the form and show the error banner', (
    tester,
  ) async {
    final harness = buildAuthHarness(
      (_) async => errorEnvelope(401, 'auth.token_invalid', 'Invalid token.'),
    );
    addTearDown(harness.dispose);

    await tester.pumpWidget(_appUnder(harness));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('signIn.tokenField')), 'bogus');
    await tester.tap(find.byKey(const Key('signIn.submit')));
    await tester.pumpAndSettle();

    // Still on the form, banner visible, no token persisted.
    expect(find.byKey(const Key('signIn.title')), findsOneWidget);
    expect(find.byKey(const Key('signIn.errorBanner')), findsOneWidget);
    // ErrorPresenter maps an authorization failure to the sign-in-again copy.
    expect(find.textContaining('session has expired'), findsOneWidget);
    expect(await harness.store.read(), isNull);
  });

  testWidgets('lost connection shows the transient (connection) message', (
    tester,
  ) async {
    final harness = buildAuthHarness(
      (_) async => throw Exception('socket reset'),
    );
    addTearDown(harness.dispose);

    await tester.pumpWidget(_appUnder(harness));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('signIn.tokenField')),
      'good-but-offline',
    );
    await tester.tap(find.byKey(const Key('signIn.submit')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('signIn.errorBanner')), findsOneWidget);
    expect(find.textContaining('check your connection'), findsOneWidget);
    // Transient failure keeps the token for a retry.
    expect(await harness.store.read(), 'good-but-offline');
  });

  testWidgets('sign-out from the account screen returns to the sign-in form', (
    tester,
  ) async {
    final harness = buildAuthHarness(
      (_) async => okMe(sampleUser),
      seedToken: 'saved-jwt',
    );
    addTearDown(harness.dispose);

    await tester.pumpWidget(_appUnder(harness));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('account.title')), findsOneWidget);

    await tester.tap(find.byKey(const Key('account.signOut')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('signIn.title')), findsOneWidget);
    expect(await harness.store.read(), isNull);
  });
}
