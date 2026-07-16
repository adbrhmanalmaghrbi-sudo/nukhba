import 'package:domain/src/competition/fixture_ref.dart';
import 'package:shared/shared.dart';

/// The *actual* final score of a single fixture — the counterpart to a
/// [FixtureScorePrediction] that Scoring compares against (Axiom 3, the single
/// football seam; Next-Task decision 2026-07-11: option (a), a minimal
/// `FixtureResult` behind that same seam, is APPROVED and MANDATORY).
///
/// Deliberately **the same shape** as a predicted score — a pair of
/// non-negative goal tallies (home vs. away) keyed by [fixture] — so that
/// scoring is a straight comparison of two identically-shaped outcomes. This is
/// the platform's one concession to "football": we do **not** build a general
/// "sports outcome" abstraction (Axiom 3). Later, when a full Football-Data
/// aggregate lands, it can supply values in exactly this shape without Scoring
/// changing.
///
/// It carries **no** competition, round, group, participant, or prediction
/// reference (Axiom 3: a fixture is competition-unaware; the same fixture may
/// feed many rounds across many competitions). The binding of a fixture to a
/// round lives in Competition's `RoundFixture`; the binding of a result to a
/// round for scoring is made by the enclosing scoring use-case, not by this
/// value. Pure and immutable; value-comparable by
/// `(fixture, homeGoals, awayGoals)`.
final class FixtureResult {
  const FixtureResult._({
    required this.fixture,
    required this.homeGoals,
    required this.awayGoals,
  });

  /// Rehydrates an actual result from already-trusted stored fields.
  ///
  /// Used by infrastructure adapters mapping a persisted `scoring.fixture_results`
  /// row back into the domain; the stored values were validated by [create] (and
  /// the DB check constraints, Axiom 6) before they were ever written.
  const FixtureResult.fromStored({
    required this.fixture,
    required this.homeGoals,
    required this.awayGoals,
  });

  /// Creates a validated actual fixture result from untrusted inputs.
  ///
  /// Both goal tallies must be non-negative and within the same defensive
  /// ceiling used for predictions ([maxGoals]) so an accidental or hostile
  /// ingestion cannot record an absurd scoreline; the ceiling is generous enough
  /// never to reject a real result. Returns a validation [AppError] otherwise
  /// (kept total — no exception escapes into a command path).
  static Result<FixtureResult> create({
    required FixtureRef fixture,
    required int homeGoals,
    required int awayGoals,
  }) {
    final homeError = _validateGoals('home', homeGoals);
    if (homeError != null) {
      return Result.err(homeError);
    }
    final awayError = _validateGoals('away', awayGoals);
    if (awayError != null) {
      return Result.err(awayError);
    }
    return Result.ok(
      FixtureResult._(
        fixture: fixture,
        homeGoals: homeGoals,
        awayGoals: awayGoals,
      ),
    );
  }

  /// The upper bound on a single side's actual goals. Deliberately identical to
  /// `FixtureScorePrediction.maxGoals` so a real result can always be compared
  /// against any accepted prediction, and mirrors the DB check constraint
  /// (Axiom 6, the backstop).
  static const int maxGoals = 99;

  static AppError? _validateGoals(String side, int goals) {
    if (goals < 0) {
      return AppError.validation(
        'scoring.result_negative',
        'Actual $side goals must not be negative',
      );
    }
    if (goals > maxGoals) {
      return AppError.validation(
        'scoring.result_out_of_range',
        'Actual $side goals must not exceed $maxGoals',
      );
    }
    return null;
  }

  /// The fixture this result belongs to (owned by Football Data; referenced by
  /// id only — Axiom 3).
  final FixtureRef fixture;

  /// The actual number of goals scored by the home side (non-negative).
  final int homeGoals;

  /// The actual number of goals scored by the away side (non-negative).
  final int awayGoals;

  /// The match outcome from the home side's perspective, derived once here so
  /// scoring logic never re-derives it (single source of truth for "who won").
  MatchOutcome get outcome {
    if (homeGoals > awayGoals) {
      return MatchOutcome.homeWin;
    }
    if (homeGoals < awayGoals) {
      return MatchOutcome.awayWin;
    }
    return MatchOutcome.draw;
  }

  @override
  bool operator ==(Object other) =>
      other is FixtureResult &&
      other.fixture == fixture &&
      other.homeGoals == homeGoals &&
      other.awayGoals == awayGoals;

  @override
  int get hashCode => Object.hash(fixture, homeGoals, awayGoals);

  @override
  String toString() =>
      'FixtureResult(fixture: ${fixture.value}, $homeGoals-$awayGoals)';
}

/// The three mutually-exclusive outcomes of a football fixture, from the home
/// side's point of view. Kept a closed set so scoring's "correct outcome"
/// comparison is total and unambiguous (Axiom 3: football-specific, not a
/// general sports notion).
enum MatchOutcome {
  /// Home side scored strictly more than the away side.
  homeWin,

  /// Both sides scored the same number of goals.
  draw,

  /// Away side scored strictly more than the home side.
  awayWin;

  /// Derives the outcome of a goal pair from the home side's perspective. Shared
  /// by [FixtureResult.outcome] and by a prediction's outcome so scoring compares
  /// like with like.
  static MatchOutcome fromGoals(int homeGoals, int awayGoals) {
    if (homeGoals > awayGoals) {
      return MatchOutcome.homeWin;
    }
    if (homeGoals < awayGoals) {
      return MatchOutcome.awayWin;
    }
    return MatchOutcome.draw;
  }
}
