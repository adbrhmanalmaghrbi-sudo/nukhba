/// The session-driven router for the app's top level.
///
/// v1 routing is deliberately minimal (Flutter App phase §4: "sign-in screen
/// if no persisted token, otherwise the home screen") and needs no routing
/// package — none is ratified in §3, and a URL-addressable router is a concern
/// of the later multi-screen slices, not the Auth slice. This widget simply
/// switches on the [SessionController]'s [SessionState]:
///   * still resolving a persisted token at boot (loading / [SessionUnknown])
///     → a splash;
///   * [SessionAuthenticated] → the [AccountScreen] (home), carrying the
///     verified principal;
///   * every other state (unauthenticated / authenticating / failed) → the
///     [SignInScreen], which itself renders progress and any typed failure.
///
/// Because the gate watches the same async provider the controller drives,
/// sign-in / sign-out / restore transitions re-route automatically with no
/// imperative navigation.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'account_screen.dart';
import 'session_controller.dart';
import 'session_state.dart';
import 'sign_in_screen.dart';

/// Chooses the top-level screen from the current authentication session.
class SessionGate extends ConsumerWidget {
  /// Creates the session gate.
  const SessionGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncSession = ref.watch(sessionControllerProvider);

    // The boot-time restore is in flight (or errored at the provider level,
    // which cannot happen here since build() is total): show a splash rather
    // than flashing the sign-in form to a returning, still-valid user.
    if (asyncSession.isLoading) {
      return const _Splash();
    }

    final session = asyncSession.value ?? const SessionUnauthenticated();
    return switch (session) {
      SessionUnknown() => const _Splash(),
      SessionAuthenticated(:final user) => AccountScreen(user: user),
      SessionUnauthenticated() ||
      SessionAuthenticating() ||
      SessionFailed() => const SignInScreen(),
    };
  }
}

/// A minimal boot splash shown while the persisted session is being resolved.
class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      key: Key('session.splash'),
      body: Center(child: CircularProgressIndicator()),
    );
  }
}
