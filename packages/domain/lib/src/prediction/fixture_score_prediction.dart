import 'package:domain/src/competition/fixture_ref.dart';
import 'package:shared/shared.dart';

/// A predicted final score for a single fixture — the outcome value object that
/// sits behind the football seam (Axiom 3).
///
/// This type is deliberately **`FixtureResult`-shaped**: the platform's one
/// concession to "football" is that a fixture's outcome is a pair of
/// non-negative goal tallies (home vs. away). The single abstraction seam
/// (Axiom 3) means we do **not** introduce a general "sports outcome"
/// abstraction here; when a `FixtureResult` aggregate lands in the Football Data
/// phase, scoring compares that result against this prediction shape directly.
///
/// It references the fixture it predicts by id only ([fixture]), never reaching
/// into the Football Data aggregate (Axiom 3: a `Fixture` carries no competition
/// awareness, and predictions likewise name fixtures by reference). It carries
/// **no** competition, round, group, or participant reference — those belong to
/// the enclosing [Prediction] aggregate, keeping this a pure, reusable outcome
/// value (Axiom 4: predict once, rank everywhere).
///
/// Pure and immutable; value-comparable by `(fixture, homeGoals, awayGoals)`.
final class FixtureScorePrediction {
  const FixtureScorePrediction._({
    required this.fixture,
    required this.homeGoals,
    required this.awayGoals,
  });

  /// Rehydrates a prediction outcome from already-trusted stored fields.
  ///
  /// Used by infrastructure adapters mapping a persisted row back into the
  /// domain; the stored values were validated by [create] (and the DB check
  /// constraints, Axiom 6) before they were ever written.
  const FixtureScorePrediction.fromStored({
    required this.fixture,
    required this.homeGoals,
    required this.awayGoals,
  });

  /// Creates a validated fixture score prediction from untrusted inputs.
  ///
  /// Both goal tallies must be non-negative and within a sane ceiling
  /// ([maxGoals]) so that an accidental or hostile client cannot submit an
  /// absurd value; the ceiling is generous enough to never reject a real
  /// scoreline. Returns a validation [AppError] otherwise (kept total — no
  /// exception escapes into a command path).
  static Result<FixtureScorePrediction> create({
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
      FixtureScorePrediction._(
        fixture: fixture,
        homeGoals: homeGoals,
        awayGoals: awayGoals,
      ),
    );
  }

  /// The upper bound on a single side's predicted goals. A defensive ceiling —
  /// no real football scoreline approaches it — that keeps stored values sane
  /// and mirrors the DB check constraint (Axiom 6, the backstop).
  static const int maxGoals = 99;

  static AppError? _validateGoals(String side, int goals) {
    if (goals < 0) {
      return AppError.validation(
        'prediction.score_negative',
        'Predicted $side goals must not be negative',
      );
    }
    if (goals > maxGoals) {
      return AppError.validation(
        'prediction.score_out_of_range',
        'Predicted $side goals must not exceed $maxGoals',
      );
    }
    return null;
  }

  /// The fixture this score predicts (owned by Football Data; referenced by id
  /// only — Axiom 3).
  final FixtureRef fixture;

  /// The predicted number of goals for the home side (non-negative).
  final int homeGoals;

  /// The predicted number of goals for the away side (non-negative).
  final int awayGoals;

  @override
  bool operator ==(Object other) =>
      other is FixtureScorePrediction &&
      other.fixture == fixture &&
      other.homeGoals == homeGoals &&
      other.awayGoals == awayGoals;

  @override
  int get hashCode => Object.hash(fixture, homeGoals, awayGoals);

  @override
  String toString() =>
      'FixtureScorePrediction(fixture: ${fixture.value}, '
      '$homeGoals-$awayGoals)';
}
