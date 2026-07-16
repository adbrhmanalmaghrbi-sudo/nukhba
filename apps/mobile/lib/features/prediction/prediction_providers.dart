/// The Prediction **read** state — annotation-based Riverpod providers that
/// expose the caller's own stored prediction for a round.
///
/// ## Scope (Flutter App phase, Core decision #1 — submit)
/// This slice renders the open round + its fixtures (REUSING the Competition
/// browse providers `roundDetailProvider` / `roundFixturesProvider` — the read
/// logic is not duplicated here, per the session mandate) and lets the caller
/// submit or amend a prediction. The single genuinely-new read this file owns
/// is [myPredictionProvider]: the caller's *own* prediction for a round, used
/// to pre-fill the form when amending and to show "already submitted" state.
///
/// ## Wiring
/// All networking is the ratified `api_client` via [PredictionApi] (obtained
/// from `core/providers.dart`'s `predictionApiProvider`); `apps/mobile`
/// performs no HTTP itself. The submit path lives in `prediction_controller.dart`
/// (a mutation), NOT here — this file holds only the read.
///
/// ## The not-found convention (deliberate, not an error)
/// `GET /rounds/{id}/predictions` returns `404 prediction.not_found` when the
/// caller has joined but not yet predicted (or is not a participant). The
/// [PredictionApi] surfaces that as `Err(invariant, code: prediction.not_found)`.
/// For the form's purposes that is a *legitimate* "nothing submitted yet" state,
/// NOT a failure — so [myPredictionProvider] maps exactly that code to
/// `Ok(null)` (no existing prediction) and rethrows every other error as the
/// typed [AppError] (rendered via `ErrorPresenter`). This mirrors how the browse
/// list providers treat an empty list as a legitimate success rather than an
/// error, keeping the distinction "no data yet" vs "real failure" explicit.
library;

import 'package:api_client/api_client.dart';
import 'package:contracts/contracts.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared/shared.dart';

import '../../core/providers.dart';

part 'prediction_providers.g.dart';

/// The stable server code for "the caller has not predicted this round yet".
///
/// Exposed as a constant (not an inline string) so the provider below and its
/// tests reference the exact same token the server/`PredictionApi` produce.
const String predictionNotFoundCode = 'prediction.not_found';

/// `GET /rounds/{id}/predictions` — the caller's own prediction for [roundId],
/// or `null` when they have not submitted one yet.
///
/// A `prediction.not_found` outcome is mapped to `null` (a legitimate
/// "nothing yet" state that pre-fills the form as blank); any other `Err`
/// (authorization, transient, a different invariant, malformed body) is
/// rethrown as the typed [AppError] so the watching widget receives it as
/// `AsyncError` and renders it through `ErrorPresenter`.
@riverpod
Future<PredictionDto?> myPrediction(Ref ref, String roundId) async {
  final api = ref.watch(predictionApiProvider);
  final result = await api.getMyPrediction(roundId);
  return switch (result) {
    Ok<PredictionDto>(:final value) => value,
    // "Nothing submitted yet" is not a failure for the form — surface as null.
    Err<PredictionDto>(:final error)
        when error.code == predictionNotFoundCode =>
      null,
    Err<PredictionDto>(:final error) => throw error,
  };
}
