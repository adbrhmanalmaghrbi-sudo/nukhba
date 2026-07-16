import 'package:domain/src/competition/fixture_ref.dart';
import 'package:shared/shared.dart';

/// How well a single fixture prediction matched the actual result — a closed,
/// ordered classification (Axiom 3: football-specific).
///
/// The three grades are mutually exclusive and ordered by specificity:
/// exact ⊃ correctOutcome ⊃ incorrect. Scoring maps each grade to a point award
/// from the frozen ruleset; nothing else can grade a fixture.
enum FixtureScoreGrade {
  /// The predicted scoreline exactly matched the actual scoreline (which implies
  /// the outcome matched too).
  exactScoreline,

  /// The predicted match outcome (home win / draw / away win) matched, but the
  /// exact scoreline did not.
  correctOutcome,

  /// Neither the outcome nor the scoreline matched.
  incorrect;

  /// The stable wire/storage token for this grade, decoupled from the Dart
  /// identifier so persisted values can never drift silently.
  String get wireValue => switch (this) {
    FixtureScoreGrade.exactScoreline => 'exact_scoreline',
    FixtureScoreGrade.correctOutcome => 'correct_outcome',
    FixtureScoreGrade.incorrect => 'incorrect',
  };

  /// Parses a [FixtureScoreGrade] from an untrusted [raw] token (e.g. a stored
  /// row), returning a validation [AppError] when absent or unrecognized.
  static Result<FixtureScoreGrade> tryParse(String? raw) {
    for (final value in FixtureScoreGrade.values) {
      if (value.wireValue == raw) {
        return Result.ok(value);
      }
    }
    return Result.err(
      AppError.validation(
        'scoring.grade_unknown',
        'Unknown fixture score grade: ${raw ?? '<null>'}',
      ),
    );
  }
}

/// The scored outcome of one fixture within a round: the [grade] earned and the
/// [points] that grade is worth under the round's frozen ruleset.
///
/// A pure read value produced entirely server-side by the scoring function
/// (Axioms 2/5: the client never computes points). It names the [fixture] by id
/// only (Axiom 3) and carries no participant/round reference — those belong to
/// the enclosing [RoundScore]. Immutable; value-comparable.
final class FixtureScoreResult {
  /// Creates a fixture score result. Constructed only by the domain scoring
  /// function and by infrastructure rehydration of an already-scored row; both
  /// sources are trusted, so no re-validation is performed here.
  const FixtureScoreResult({
    required this.fixture,
    required this.grade,
    required this.points,
  });

  /// The fixture this result grades (by id — Axiom 3).
  final FixtureRef fixture;

  /// How the prediction for this fixture matched the actual result.
  final FixtureScoreGrade grade;

  /// The points awarded for this fixture under the round's frozen ruleset
  /// (non-negative; server-computed).
  final int points;

  @override
  bool operator ==(Object other) =>
      other is FixtureScoreResult &&
      other.fixture == fixture &&
      other.grade == grade &&
      other.points == points;

  @override
  int get hashCode => Object.hash(fixture, grade, points);

  @override
  String toString() =>
      'FixtureScoreResult(fixture: ${fixture.value}, '
      '${grade.wireValue}, points: $points)';
}
