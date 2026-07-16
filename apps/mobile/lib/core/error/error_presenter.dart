/// The single place that turns a typed [AppError] into a user-facing message.
///
/// Every failure in the app arrives as `shared`'s `AppError` (from a
/// `Result.err` produced by `api_client`). Presentation logic lives here once
/// so screens never branch on raw `code` strings ad hoc — they call
/// [ErrorPresenter.message] (and, where useful, [ErrorPresenter.isRetryable]).
///
/// Messages are intentionally terse and non-technical; the stable `code` is
/// used to special-case the handful of business outcomes the Core screens must
/// distinguish (e.g. "you haven't predicted yet" vs a real error), keeping the
/// mapping in one auditable table rather than scattered across widgets.
library;

import 'package:shared/shared.dart';

/// Maps typed errors to human text. Pure and stateless.
abstract final class ErrorPresenter {
  /// A short, user-readable description of [error].
  ///
  /// Known stable codes are given tailored copy; everything else falls back to
  /// a message keyed on the [ErrorKind] so the user always sees something
  /// sensible and never a raw exception.
  static String message(AppError error) {
    switch (error.code) {
      case 'leaderboard.not_a_participant':
        return 'You are not a member of this season, so its leaderboard is '
            'not visible to you.';
      case 'prediction.not_found':
        return 'You have not submitted a prediction for this round yet.';
      case 'prediction.round_not_locked':
        return 'Other players\' predictions become visible only after the '
            'round locks.';
      case 'prediction.not_a_participant':
        return 'You have not joined this competition, so you cannot see this.';
      case 'competition.not_found':
        return 'This competition could not be found.';
      case 'competition.round_not_found':
        return 'This round could not be found.';
    }

    return switch (error.kind) {
      ErrorKind.authorization =>
        'You are not signed in, or your session has expired. '
            'Please sign in again.',
      ErrorKind.invariant =>
        error.message.isNotEmpty
            ? error.message
            : 'That action is not allowed right now.',
      ErrorKind.validation =>
        error.message.isNotEmpty
            ? error.message
            : 'Some of the information provided is invalid.',
      ErrorKind.transient =>
        'We could not reach the server. Please check your connection and try '
            'again.',
    };
  }

  /// Whether the user should be offered a "retry" affordance for [error].
  ///
  /// Only transient/infrastructure failures are safely retryable
  /// ([AppError.isRetryable]); a terminal business/validation/authorization
  /// outcome is not retried by re-issuing the same request.
  static bool isRetryable(AppError error) => error.isRetryable;

  /// Whether [error] means the caller's session is missing or invalid, so the
  /// app should route them back to sign-in.
  static bool isAuthFailure(AppError error) =>
      error.kind == ErrorKind.authorization;
}
