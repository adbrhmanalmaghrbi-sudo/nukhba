import 'package:domain/src/competition/participant_id.dart';
import 'package:domain/src/competition/round_id.dart';
import 'package:domain/src/scoring/fixture_score_result.dart';
import 'package:shared/shared.dart';

/// A single participant's scored result for a single round — the output of the
/// Scoring phase for one forecast.
///
/// It names the [roundId] and [participantId] by id only (never the Round or
/// Participant entity), carries the per-fixture [fixtureResults] and the derived
/// [totalPoints], and records which [rulesetVersion] governed the scoring (so a
/// score can always be traced to the exact frozen rules — Axiom 5,
/// reproducibility). It carries **no** group reference (Axiom 4: one score,
/// ranked everywhere).
///
/// Points here are a **server-computed read value**. They are not yet the
/// competitive-record instrument — turning them into append-only `PointEntry`s
/// and a balance projection is the Ledger phase (Axiom 5). Scoring nonetheless
/// treats them as server-owned: only [score] (the domain scoring function) or
/// trusted rehydration can construct a [RoundScore]. Pure and immutable.
final class RoundScore {
  const RoundScore._({
    required this.roundId,
    required this.participantId,
    required this.rulesetVersion,
    required this.totalPoints,
    required this.fixtureResults,
  });

  /// Rehydrates a round score from already-trusted stored fields (infrastructure
  /// mapper). The stored values were produced by [score] before they were
  /// written, so no re-validation or re-summation is performed.
  RoundScore.fromStored({
    required this.roundId,
    required this.participantId,
    required this.rulesetVersion,
    required this.totalPoints,
    required List<FixtureScoreResult> fixtureResults,
  }) : fixtureResults = List<FixtureScoreResult>.unmodifiable(fixtureResults);

  /// The round this score is for (by id).
  final RoundId roundId;

  /// The participant this score belongs to (by id). Combined with [roundId] this
  /// is the natural key — exactly one score per (participant, round), mirroring
  /// the one prediction per (participant, round) it was computed from (Axiom 4).
  final ParticipantId participantId;

  /// The version of the frozen ruleset used to compute this score.
  final int rulesetVersion;

  /// The sum of every fixture's points — derived once by [score] and stored, so
  /// reads never re-sum. Always equals the sum of [fixtureResults] points.
  final int totalPoints;

  /// The per-fixture breakdown, in the order the prediction listed its fixtures.
  /// Always an unmodifiable list.
  final List<FixtureScoreResult> fixtureResults;

  @override
  bool operator ==(Object other) =>
      other is RoundScore &&
      other.roundId == roundId &&
      other.participantId == participantId &&
      other.rulesetVersion == rulesetVersion &&
      other.totalPoints == totalPoints &&
      _listEquals(other.fixtureResults, fixtureResults);

  @override
  int get hashCode => Object.hash(
    roundId,
    participantId,
    rulesetVersion,
    totalPoints,
    Object.hashAll(fixtureResults),
  );

  @override
  String toString() =>
      'RoundScore(round: ${roundId.value}, '
      'participant: ${participantId.value}, v$rulesetVersion, '
      'total: $totalPoints, fixtures: ${fixtureResults.length})';

  static bool _listEquals(
    List<FixtureScoreResult> a,
    List<FixtureScoreResult> b,
  ) {
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }

  /// Builds a [RoundScore] from already-graded fixture results, summing their
  /// points. Used only internally by the scoring function after it has graded
  /// every fixture; not exposed for arbitrary construction (points are
  /// server-owned).
  static Result<RoundScore> fromGraded({
    required RoundId roundId,
    required ParticipantId participantId,
    required int rulesetVersion,
    required List<FixtureScoreResult> fixtureResults,
  }) {
    if (fixtureResults.isEmpty) {
      return const Result.err(
        AppError.invariant(
          'scoring.no_fixtures_scored',
          'A round score must grade at least one fixture',
        ),
      );
    }
    var total = 0;
    for (final result in fixtureResults) {
      total += result.points;
    }
    return Result.ok(
      RoundScore._(
        roundId: roundId,
        participantId: participantId,
        rulesetVersion: rulesetVersion,
        totalPoints: total,
        fixtureResults: List<FixtureScoreResult>.unmodifiable(fixtureResults),
      ),
    );
  }
}
