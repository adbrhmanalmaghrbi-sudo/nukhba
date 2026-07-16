import 'package:domain/domain.dart';

/// A read model that pairs a [Prediction] aggregate with the **submission
/// instant** the repository stamped on it.
///
/// Why this exists (application-layer amendment, 2026-07-11): the domain
/// [Prediction] deliberately carries no `submittedAt` — the submission instant
/// is a persistence fact owned by the repository (`save`/`update` take it as a
/// parameter; every read query already selects `submitted_at`), not a domain
/// invariant of the forecast. But the versioned wire shape `PredictionDto`
/// (contracts) requires `submittedAt`, so the edge cannot construct a faithful
/// DTO from a bare [Prediction] without fabricating a timestamp (forbidden) or
/// dropping a required field (breaks the contract).
///
/// This view closes that gap without polluting the domain: the three
/// prediction use-cases (`SubmitPrediction`, `GetMyPrediction`,
/// `ListRoundPredictions`) return the entity **alongside** its stored
/// submission instant, so the route maps directly to `PredictionDto`. The SQL
/// and the migration are unchanged — only the application read layer's return
/// shape carries the extra fact it always had access to.
///
/// Pure and immutable; value-comparable by `(prediction, submittedAt)`.
final class PredictionView {
  /// Pairs [prediction] with the UTC [submittedAt] instant it was stored under.
  const PredictionView({required this.prediction, required this.submittedAt});

  /// The prediction aggregate (identity, round/participant binding, scores).
  final Prediction prediction;

  /// The submission instant (UTC) the repository stamped on this prediction.
  ///
  /// For an amended prediction this is the amendment instant — the same row's
  /// `submitted_at` is refreshed on `update` (Axiom 4: one row per round).
  final DateTime submittedAt;

  @override
  bool operator ==(Object other) =>
      other is PredictionView &&
      other.prediction == prediction &&
      other.submittedAt == submittedAt;

  @override
  int get hashCode => Object.hash(prediction, submittedAt);
}
