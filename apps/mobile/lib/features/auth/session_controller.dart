/// The single source of truth for the client's authentication session.
///
/// This annotation-based Riverpod controller (`@riverpod`) owns the transition
/// between the [SessionState] cases and is the only place that reads/writes the
/// [TokenStore] and calls `AuthApi.me()`. Widgets never touch the token store
/// or `api_client` directly — they watch this controller and call its methods.
///
/// ## Sign-in mechanism (contract-faithful for v1)
/// The ratified backend has **no** password/login route — Supabase mints the
/// access token (Auth phase; the server only *verifies* every token, Security
/// ADR §2). The only identity route that exists is `GET /me` behind
/// `bearerAuth`. So the client's "sign in" is: accept an access token, persist
/// it via the [TokenStore], then **validate it by calling `GET /me`**:
///   * `200` → the token is good; hold the returned principal ([SessionAuthenticated]).
///   * `401` (authorization) → the token is invalid/expired; the persisted
///     token is cleared and the attempt becomes [SessionFailed] (never a
///     half-signed-in state holding a rejected token).
///   * transient (network/`503`) → the token is *kept* (the failure is not the
///     token's fault) and the attempt becomes [SessionFailed]; the user may
///     retry without re-entering it.
///
/// ## Boot-time restore
/// [build] reads any persisted token once; if present it validates it exactly
/// as a sign-in does, so a returning user with a still-valid token lands
/// directly on the authenticated screen, and one whose token has since expired
/// is routed to sign-in with the stale token cleared.
library;

import 'dart:async';

import 'package:api_client/api_client.dart';
import 'package:contracts/contracts.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared/shared.dart';

import '../../core/auth/token_store.dart';
import '../../core/providers.dart';
import 'session_state.dart';

part 'session_controller.g.dart';

/// Owns and mutates the authentication [SessionState].
///
/// The controller is async: [build] resolves the boot-time state by attempting
/// a restore from the [TokenStore], so the initial value is a `Future` that the
/// router awaits (showing a splash while it is [SessionUnknown]/loading).
@riverpod
class SessionController extends _$SessionController {
  TokenStore get _store => ref.read(tokenStoreProvider);
  AuthApi get _authApi => ref.read(authApiProvider);

  @override
  Future<SessionState> build() async {
    return _restore();
  }

  /// Boot-time restore: validate a persisted token, if any.
  Future<SessionState> _restore() async {
    final token = await _store.read();
    if (token == null || token.isEmpty) {
      return const SessionUnauthenticated();
    }
    // A token is on disk — confirm the server still accepts it before treating
    // the user as signed in.
    return _validateHeldToken(clearOnAuthFailure: true);
  }

  /// Signs in with an access [token] (minted by Supabase / supplied by the
  /// caller): persist it, then validate via `GET /me`.
  ///
  /// The state moves to [SessionAuthenticating] for the duration, then to
  /// [SessionAuthenticated] on success or [SessionFailed] on any error.
  Future<void> signIn(String token) async {
    final trimmed = token.trim();
    if (trimmed.isEmpty) {
      state = const AsyncData(
        SessionFailed(
          AppError.validation(
            'auth.token_empty',
            'Please enter your access token.',
          ),
        ),
      );
      return;
    }

    state = const AsyncData(SessionAuthenticating());
    // Persist first so the transport's TokenProvider attaches it to the /me
    // probe; a rejected token is cleared again below.
    await _store.write(trimmed);
    final resolved = await _validateHeldToken(clearOnAuthFailure: true);
    state = AsyncData(resolved);
  }

  /// Signs the current user out: clear the persisted token and drop to
  /// [SessionUnauthenticated]. Idempotent.
  Future<void> signOut() async {
    await _store.clear();
    state = const AsyncData(SessionUnauthenticated());
  }

  /// Re-attempts validation of the currently-held token (used by the "retry"
  /// affordance after a transient failure, where the token was intentionally
  /// kept). No-op-safe: if no token is held it resolves to unauthenticated.
  Future<void> retry() async {
    state = const AsyncData(SessionAuthenticating());
    final resolved = await _restore();
    state = AsyncData(resolved);
  }

  /// Calls `GET /me` with whatever token the store currently holds and maps the
  /// typed `Result` to a [SessionState].
  ///
  /// On an authorization failure the persisted token is cleared (when
  /// [clearOnAuthFailure]) because it is definitively bad; on a transient
  /// failure the token is left in place so a retry can succeed without the user
  /// re-entering it.
  Future<SessionState> _validateHeldToken({
    required bool clearOnAuthFailure,
  }) async {
    final Result<MeResponseDto> result = await _authApi.me();
    return switch (result) {
      Ok<MeResponseDto>(:final value) => SessionAuthenticated(value.user),
      Err<MeResponseDto>(:final error) => await _onValidationError(
        error,
        clearOnAuthFailure: clearOnAuthFailure,
      ),
    };
  }

  Future<SessionState> _onValidationError(
    AppError error, {
    required bool clearOnAuthFailure,
  }) async {
    if (error.kind == ErrorKind.authorization && clearOnAuthFailure) {
      await _store.clear();
    }
    return SessionFailed(error);
  }
}
