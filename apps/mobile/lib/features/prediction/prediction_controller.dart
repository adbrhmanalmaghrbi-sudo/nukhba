/// The Prediction **submit** controller — the annotation-based Riverpod notifier
/// that owns the [SubmissionState] lifecycle for a single round.
///
/// ## Responsibility
/// This is the ONLY place `apps/mobile` triggers a prediction *write*. It drives
/// the sealed [SubmissionState] (`Idle → InFlight → Succeeded | Failed`) through
/// exactly one call to `PredictionApi.submitPrediction` (from the ratified
/// `api_client`, obtained via `core/providers.dart`'s `predictionApiProvider`);
/// the app performs no HTTP itself (ADR-002 §2.8). It mirrors the discipline of
/// `session_controller.dart`: the notifier is the single owner of the state
/// transitions and the only caller of the relevant `api_client` surface, and
/// widgets never touch `api_client` or branch on raw codes — they watch this
/// controller and call [submit] / [reset].
///
/// ## The form ↔ contract binding (Axioms 2/5)
/// The screen collects one predicted scoreline per fixture in the round (read
/// from the reused Competition browse providers `roundDetailProvider` /
/// `roundFixturesProvider`, and — when amending — pre-filled from
/// `myPredictionProvider`). Those scorelines are passed to [submit] verbatim as
/// `List<FixtureScoreDto>` — the exact `SubmitPredictionCommandDto` body shape
/// the server expects. NO points, participant id, or computed value is ever sent
/// or fabricated client-side: the participant is resolved server-side from the
/// verified principal, and points are a Scoring/Ledger concern. Server-side
/// completeness (exactly one score per round fixture), round-open, participant,
/// and idempotent-amend rules are enforced by `SubmitPrediction` in `apps/server`
/// — this controller does not re-implement them; it surfaces their typed
/// failures.
///
/// ## Success invalidates the read
/// On a `200` the controller moves to [SubmissionSucceeded] carrying the stored
/// [PredictionDto], and invalidates `myPredictionProvider(roundId)` so any
/// widget showing the "already submitted" read re-fetches and reflects the new
/// (or amended) prediction. Amending an existing prediction is exactly the same
/// call — the server upserts one row per `(participant, round)` (Axiom 4) — so
/// there is no separate "edit" path here.
///
/// ## Failure keeps the form editable
/// Any `Err` (a `400` incomplete/malformed forecast → `validation`; a `409`
/// locked round / not-a-participant → `invariant`/`authorization`; a network/
/// `503` → `transient`) becomes [SubmissionFailed] carrying the typed
/// [AppError]. The screen renders it via `ErrorPresenter` and stays editable so
/// the user can correct and retry; the controller never clears the user's input.
library;

import 'package:api_client/api_client.dart';
import 'package:contracts/contracts.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared/shared.dart';

import '../../core/providers.dart';
import 'prediction_providers.dart';
import 'prediction_submission.dart';

part 'prediction_controller.g.dart';

/// The stable client-side code for an empty submit attempt (no fixtures at all).
///
/// Exposed as a constant so the controller and its tests reference the exact
/// same token. This guards only the degenerate "there is nothing to submit"
/// case locally (a round with zero fixtures, or a form built before its fixtures
/// loaded); every other completeness rule — including "a score for each fixture
/// in the round" — is the server's `SubmitPrediction` invariant and is surfaced
/// as the server's typed error, not re-derived here.
const String predictionEmptySubmissionCode = 'prediction.empty_submission';

/// Owns and mutates the [SubmissionState] for the round identified by [roundId].
///
/// A `family` notifier (one instance per round): the submit lifecycle of one
/// round is independent of any other. The initial state is [SubmissionIdle]
/// (the form is editable, nothing in flight); a returning caller amending an
/// existing prediction starts here too — the pre-fill is a *read* concern
/// (`myPredictionProvider`), while this controller only tracks the write.
@riverpod
class PredictionController extends _$PredictionController {
  PredictionApi get _api => ref.read(predictionApiProvider);

  @override
  SubmissionState build(String roundId) => const SubmissionIdle();

  /// Submits (or idempotently amends) the caller's prediction for [roundId] with
  /// the collected [fixtureScores].
  ///
  /// Transitions `→ InFlight` for the duration of the single
  /// `POST /rounds/{id}/predictions` call, then `→ Succeeded(prediction)` on a
  /// `200` (also invalidating `myPredictionProvider(roundId)` so the read
  /// refreshes) or `→ Failed(error)` on any typed failure. A second call while a
  /// submit is already [SubmissionInFlight] is ignored (the screen also disables
  /// the affordance, but this is the authoritative guard against a double
  /// submit). An empty [fixtureScores] is refused locally as a `validation`
  /// failure without touching the network.
  Future<void> submit(List<FixtureScoreDto> fixtureScores) async {
    // Do not fire a second overlapping request; the in-flight one wins.
    if (state is SubmissionInFlight) {
      return;
    }

    if (fixtureScores.isEmpty) {
      state = const SubmissionFailed(
        AppError.validation(
          predictionEmptySubmissionCode,
          'Enter a score for each fixture before submitting.',
        ),
      );
      return;
    }

    state = const SubmissionInFlight();

    final Result<PredictionDto> result = await _api.submitPrediction(
      roundId: roundId,
      fixtureScores: fixtureScores,
    );

    state = switch (result) {
      Ok<PredictionDto>(:final value) => SubmissionSucceeded(value),
      Err<PredictionDto>(:final error) => SubmissionFailed(error),
    };

    // On success, the caller's stored prediction changed — refresh the read so
    // any "already submitted" surface reflects the new/amended prediction.
    if (state is SubmissionSucceeded) {
      ref.invalidate(myPredictionProvider(roundId));
    }
  }

  /// Returns the controller to [SubmissionIdle] (e.g. after the user dismisses a
  /// success confirmation, or to clear a prior failure before editing again).
  /// A no-op while a submit is [SubmissionInFlight] — an attempt in flight is
  /// not silently discarded.
  void reset() {
    if (state is SubmissionInFlight) {
      return;
    }
    state = const SubmissionIdle();
  }
}
