/// The client's authentication session state — a small, exhaustive,
/// value-comparable model the UI switches over.
///
/// It is deliberately independent of *how* the token is obtained: a session is
/// either unknown (still resolving a persisted token at boot), unauthenticated
/// (no valid token — show sign-in), authenticating (a sign-in / restore is in
/// flight), authenticated (we hold a token the server accepted, carrying the
/// canonical [AuthenticatedUserDto] from `GET /me`), or failed (the last
/// sign-in attempt produced a typed [AppError] to present).
///
/// The sealed hierarchy lets the analyzer enforce exhaustive `switch` in the
/// widgets (Coding Standards ADR §4 — illegal states unrepresentable).
library;

import 'package:contracts/contracts.dart';
import 'package:shared/shared.dart';

/// Base type of every authentication session state. Sealed so callers must
/// handle each case.
sealed class SessionState {
  const SessionState();
}

/// The initial, transient state while the app checks secure storage for a
/// previously-persisted token at startup. The router shows a splash/loading
/// affordance for this state, never the sign-in form (so a returning user is
/// not briefly shown a login screen before their session is restored).
final class SessionUnknown extends SessionState {
  /// Creates the boot-time unknown state.
  const SessionUnknown();

  @override
  bool operator ==(Object other) => other is SessionUnknown;

  @override
  int get hashCode => (SessionUnknown).hashCode;
}

/// No valid session: either no token was persisted, or a restore/sign-out
/// cleared it. The router shows the sign-in screen.
final class SessionUnauthenticated extends SessionState {
  /// Creates the signed-out state.
  const SessionUnauthenticated();

  @override
  bool operator ==(Object other) => other is SessionUnauthenticated;

  @override
  int get hashCode => (SessionUnauthenticated).hashCode;
}

/// A sign-in (or boot-time restore) is in flight. The UI shows progress and
/// disables the submit affordance.
final class SessionAuthenticating extends SessionState {
  /// Creates the in-flight state.
  const SessionAuthenticating();

  @override
  bool operator ==(Object other) => other is SessionAuthenticating;

  @override
  int get hashCode => (SessionAuthenticating).hashCode;
}

/// A valid session: the server accepted the held token and returned the
/// canonical principal ([user], the `GET /me` payload). The router shows the
/// authenticated home/account screen.
final class SessionAuthenticated extends SessionState {
  /// Creates an authenticated state carrying the verified [user].
  const SessionAuthenticated(this.user);

  /// The canonical platform identity as returned by `GET /me`.
  final AuthenticatedUserDto user;

  @override
  bool operator ==(Object other) =>
      other is SessionAuthenticated && other.user == user;

  @override
  int get hashCode => user.hashCode;
}

/// The last sign-in attempt failed. Carries the typed [error] so the UI can
/// render a message via `ErrorPresenter` and decide on a retry affordance.
/// This is distinct from [SessionUnauthenticated]: the form stays populated and
/// an error is shown, rather than a clean signed-out screen.
final class SessionFailed extends SessionState {
  /// Creates a failed sign-in state carrying [error].
  const SessionFailed(this.error);

  /// The typed failure from the sign-in attempt.
  final AppError error;

  @override
  bool operator ==(Object other) =>
      other is SessionFailed && other.error == error;

  @override
  int get hashCode => error.hashCode;
}
