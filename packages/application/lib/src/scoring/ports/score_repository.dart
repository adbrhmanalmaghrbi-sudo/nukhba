import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// Persistence port for computed **round scores** (Application ADR, Section 9:
/// use-cases depend on repository interfaces; Infrastructure implements them).
///
/// Backed by `PostgresScoreRepository` over the new `scoring.round_scores` +
/// `scoring.round_score_fixtures` tables. The interface speaks in the domain
/// [RoundScore] aggregate and typed ids, never rows or SQL.
///
/// A score is a **server-owned read value** (Axioms 2/5): only the scoring
/// use-case (fed by the pure `Scoring.scoreRound`) ever produces the
/// [RoundScore]s written here; the client never submits or computes points. The
/// competitive record they will become is the Ledger phase's concern — this
/// port only persists the derived scores.
///
/// General contract for every method (Application ADR, Section 2):
/// * MUST NOT throw — every outcome is a typed [Result].
/// * MUST map infrastructure failures to [ErrorKind.transient].
/// * MUST map a storage-only integrity conflict to [ErrorKind.invariant].
abstract interface class ScoreRepository {
  /// Persists every [scores] entry for a round **atomically** (all-or-nothing),
  /// replacing any previously stored score for the same `(round, participant)`
  /// in place so re-scoring the same round is idempotent (Axiom 4: one score per
  /// participant per round, never a second row). The whole batch is one
  /// transaction — a mid-write failure must leave no partial round scored
  /// (Axiom 5, the competitive record must never be half-written).
  ///
  /// Every [RoundScore] in [scores] MUST share the same round; the adapter does
  /// not mix rounds in a single call.
  Future<Result<void>> saveRoundScores(List<RoundScore> scores);

  /// Lists every participant's [RoundScore] for [roundId], ordered by
  /// participant id for a stable read. An empty list means the round has not
  /// been scored yet (the read use-case distinguishes "not scored" via the
  /// round's status, not by emptiness).
  Future<Result<List<RoundScore>>> listByRound(RoundId roundId);
}
