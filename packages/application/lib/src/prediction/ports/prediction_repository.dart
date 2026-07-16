import 'package:application/src/prediction/prediction_view.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// Persistence port for the Prediction context (Application ADR, Section 9:
/// use-cases depend on repository interfaces; Infrastructure implements them).
///
/// Backed by `PostgresPredictionRepository`. The interface speaks in domain
/// aggregates and typed ids, never in rows or SQL, so use-cases stay pure and
/// testable against an in-memory fake.
///
/// The Prediction aggregate is deliberately **separate** from Competition
/// (Database ADR, Section 1 & 2.1: prediction writes are the platform's
/// highest-volume path and must never contend on the Competition aggregate), so
/// this is its own port rather than a method on `CompetitionRepository`.
///
/// General contract for every method (Application ADR, Section 2):
/// * MUST NOT throw — every outcome is a typed [Result].
/// * MUST map infrastructure failures to [ErrorKind.transient].
/// * MUST map a storage-only integrity conflict (e.g. the unique
///   `(participant_id, round_id)` violation) to [ErrorKind.invariant], so the
///   use-case reports it as a business-rule conflict, not a transient fault.
abstract interface class PredictionRepository {
  /// Finds the single prediction for `(roundId, participantId)`, or `Ok(null)`
  /// when the participant has not yet predicted this round.
  ///
  /// This is the read used to make submission idempotent (submit-then-amend on
  /// a retry) and to serve "get my prediction". Because "one prediction per
  /// participant per round" is the aggregate's natural key (Axiom 4), this
  /// returns at most one prediction.
  ///
  /// Returns a [PredictionView] (the prediction plus its stored `submitted_at`
  /// instant) so the edge can build the versioned `PredictionDto` without
  /// fabricating a timestamp — the query already selects `submitted_at`, so
  /// this only surfaces a fact the adapter already read.
  Future<Result<PredictionView?>> findByRoundAndParticipant(
    RoundId roundId,
    ParticipantId participantId,
  );

  /// Persists a brand-new [prediction] stamped [submittedAt] (UTC).
  ///
  /// The `(participant_id, round_id)` pair is unique — the physical "predict
  /// once" backstop (Axiom 6) — so a concurrent duplicate insert surfaces as
  /// [ErrorKind.invariant] `prediction.already_submitted`.
  Future<Result<void>> save(Prediction prediction, DateTime submittedAt);

  /// Persists an amended [prediction], replacing the stored forecast in place
  /// and refreshing its [submittedAt] (UTC). Identity (`id`, `roundId`,
  /// `participantId`) is unchanged — an amendment is the same row, never a
  /// second prediction (Axiom 4).
  ///
  /// A prediction that no longer exists (deleted between read and update) is an
  /// [ErrorKind.invariant] `prediction.not_found`.
  Future<Result<void>> update(Prediction prediction, DateTime submittedAt);

  /// Lists every prediction submitted for [roundId], across all participants,
  /// ordered by submission instant then prediction id for a stable read.
  ///
  /// Used by the "list round predictions" query, which the use-case only serves
  /// once the round is locked (Axiom 2: an open round's predictions stay
  /// private so no participant can copy another's forecast).
  ///
  /// Each entry is a [PredictionView] carrying its stored `submitted_at`
  /// instant (already ordered by), so the edge builds each `PredictionDto`
  /// faithfully.
  Future<Result<List<PredictionView>>> listByRound(RoundId roundId);

  /// Returns the set of fixtures currently linked to [roundId] (the round's
  /// `RoundFixture` composition), ordered by `displayOrder`.
  ///
  /// The `round_fixture` table is owned by the Competition migration (0002);
  /// this is a read-only projection the Prediction use-cases require to enforce
  /// the two data-integrity rules of a submission (product decision, 2026-07-10):
  /// every predicted fixture MUST belong to the round
  /// (`prediction.fixture_not_in_round`), and the submission MUST cover every
  /// linked fixture — no more, no fewer (`prediction.incomplete_forecast`).
  /// Exposed here rather than on `CompetitionRepository` so the frozen
  /// Competition port stays untouched.
  ///
  /// An empty list means the round has no fixtures linked yet — a submission is
  /// then impossible (there is nothing to predict) and the use-case rejects it.
  Future<Result<List<RoundFixture>>> listRoundFixtures(RoundId roundId);
}
