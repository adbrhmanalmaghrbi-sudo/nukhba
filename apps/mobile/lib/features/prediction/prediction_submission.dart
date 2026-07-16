/// The client's prediction-**submission** state — a small, exhaustive,
/// value-comparable model the submit screen switches over.
///
/// This is deliberately separate from the *read* of an existing prediction
/// ([myPredictionProvider] in `prediction_providers.dart`) and from the round /
/// fixtures browse reads (reused from the Competition slice). It models only the
/// lifecycle of a single submit/amend attempt:
///   * [SubmissionIdle]      — no attempt in flight; the form is editable.
///   * [SubmissionInFlight]  — a `POST /rounds/{id}/predictions` is running; the
///     screen disables the submit button and any score inputs.
///   * [SubmissionSucceeded] — the server accepted (or idempotently amended) the
///     prediction; carries the stored [PredictionDto] so the screen can confirm
///     what was saved (submitted-at, the echoed scorelines).
///   * [SubmissionFailed]    — the attempt produced a typed [AppError] (a
///     validation/authorization/invariant/transient failure), presented via
///     `ErrorPresenter`; the form stays editable so the user can correct and
///     retry.
///
/// The sealed hierarchy lets the analyzer enforce exhaustive `switch` in the
/// screen (Coding Standards ADR §4 — illegal states unrepresentable). No points
/// or computed score ever appears here (Axioms 2/5): a submission carries only
/// the user's intent and echoes back the stored prediction.
library;

import 'package:contracts/contracts.dart';
import 'package:shared/shared.dart';

/// Base type of every prediction-submission state. Sealed so callers must
/// handle each case.
sealed class SubmissionState {
  const SubmissionState();
}

/// No submission attempt has been made yet (or the screen was reset). The form
/// is editable and the submit affordance is enabled.
final class SubmissionIdle extends SubmissionState {
  /// Creates the idle state.
  const SubmissionIdle();

  @override
  bool operator ==(Object other) => other is SubmissionIdle;

  @override
  int get hashCode => (SubmissionIdle).hashCode;
}

/// A submit/amend request is in flight. The UI shows progress and disables the
/// submit affordance + the per-fixture score inputs so the user cannot fire a
/// second overlapping request.
final class SubmissionInFlight extends SubmissionState {
  /// Creates the in-flight state.
  const SubmissionInFlight();

  @override
  bool operator ==(Object other) => other is SubmissionInFlight;

  @override
  int get hashCode => (SubmissionInFlight).hashCode;
}

/// The server accepted the prediction (a first submission or an idempotent
/// amendment — one row per round either way, Axiom 4). Carries the stored
/// [prediction] so the screen can confirm exactly what was saved.
final class SubmissionSucceeded extends SubmissionState {
  /// Creates a succeeded state carrying the stored [prediction].
  const SubmissionSucceeded(this.prediction);

  /// The stored prediction the server returned (echoed intent, no points).
  final PredictionDto prediction;

  @override
  bool operator ==(Object other) =>
      other is SubmissionSucceeded && other.prediction == prediction;

  @override
  int get hashCode => prediction.hashCode;
}

/// The last submit attempt failed. Carries the typed [error] so the screen can
/// render a message via `ErrorPresenter` (e.g. incomplete forecast, round not
/// open, not a participant, network) and keep the form editable for a correction
/// or retry.
final class SubmissionFailed extends SubmissionState {
  /// Creates a failed state carrying [error].
  const SubmissionFailed(this.error);

  /// The typed failure from the submit attempt.
  final AppError error;

  @override
  bool operator ==(Object other) =>
      other is SubmissionFailed && other.error == error;

  @override
  int get hashCode => error.hashCode;
}
