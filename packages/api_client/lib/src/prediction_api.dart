import 'package:api_client/src/api_transport.dart';
import 'package:contracts/contracts.dart';
import 'package:shared/shared.dart';

/// Typed client for the Prediction surface of `apps/server`.
///
/// Wraps exactly the prediction routes that exist today, verbatim:
///   * `POST /rounds/{id}/predictions`     (submit/amend) -> [PredictionDto]
///     (`routes/rounds/[id]/predictions/index.dart`, POST branch). The body is
///     a [SubmitPredictionCommandDto] carrying ONLY the predicted scorelines;
///     the participant is resolved server-side from the verified principal,
///     never sent by the client (Security ADR §2 / Axioms 2/5). No points are
///     ever sent or received.
///   * `GET /rounds/{id}/predictions`       (mine)  -> [PredictionDto]
///     (same file, GET branch). A joined-but-not-yet-predicted caller (or a
///     non-participant) yields `404 prediction.not_found`.
///   * `GET /rounds/{id}/predictions/all`   (locked round list)
///     -> `List<PredictionDto>` (`routes/rounds/[id]/predictions/all.dart`).
///     An open round is refused `401 prediction.round_not_locked`; a
///     non-participant `401 prediction.not_a_participant`; a locked round with
///     no predictions is a legitimate empty array.
///
/// The whole `/rounds` subtree is behind `bearerAuth`. Every method returns a
/// typed [Result] and never throws. This is the ONLY prediction write path a
/// client has — there is no direct Supabase write (ADR-002 §2.2/§2.8): every
/// submission goes through the server use-case API here.
final class PredictionApi {
  /// Creates the Prediction client over the shared [ApiTransport].
  const PredictionApi(this._transport);

  final ApiTransport _transport;

  /// `POST /rounds/{id}/predictions` — submit or idempotently amend the
  /// caller's prediction for [roundId].
  ///
  /// [fixtureScores] are the predicted scorelines (one per fixture in the
  /// round). Returns the stored [PredictionDto] on `200`. Business failures
  /// surface with their stable codes, e.g.:
  ///   * incomplete forecast / malformed body -> `Err(validation)` (`400`);
  ///   * round locked / not a participant      -> `Err(invariant)` /
  ///     `Err(authorization)` per the server's mapping (`409` / `401`).
  Future<Result<PredictionDto>> submitPrediction({
    required String roundId,
    required List<FixtureScoreDto> fixtureScores,
  }) {
    final command = SubmitPredictionCommandDto(fixtureScores: fixtureScores);
    return _transport.postObject<PredictionDto>(
      '/rounds/$roundId/predictions',
      body: command.toJson(),
      parse: PredictionDto.fromJson,
    );
  }

  /// `GET /rounds/{id}/predictions` — the caller's own prediction for
  /// [roundId], any round status (self-read is safe).
  ///
  /// When the caller has not yet predicted (or is not a participant) the server
  /// returns `404 prediction.not_found`; this surfaces as
  /// `Err(invariant, code: prediction.not_found)`, letting the UI distinguish
  /// "nothing submitted yet" from a transport error via the stable code.
  Future<Result<PredictionDto>> getMyPrediction(String roundId) {
    return _transport.getObject<PredictionDto>(
      '/rounds/$roundId/predictions',
      parse: PredictionDto.fromJson,
    );
  }

  /// `GET /rounds/{id}/predictions/all` — every participant's prediction for a
  /// **locked** [roundId] (the competing pool, revealed only after lock).
  ///
  /// An empty list means the round is locked but nobody predicted (distinct
  /// from the `401 prediction.round_not_locked` "too early" refusal).
  Future<Result<List<PredictionDto>>> listRoundPredictions(String roundId) {
    return _transport.getList<PredictionDto>(
      '/rounds/$roundId/predictions/all',
      parseElement: PredictionDto.fromJson,
    );
  }
}
