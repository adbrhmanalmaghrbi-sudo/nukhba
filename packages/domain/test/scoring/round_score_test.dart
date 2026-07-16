import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

const _round = '33333333-3333-3333-3333-333333333333';
const _participant = '44444444-4444-4444-4444-444444444444';
const _fixtureA = '11111111-1111-1111-1111-111111111111';
const _fixtureB = '22222222-2222-2222-2222-222222222222';

FixtureScoreResult _fsr(String fixture, FixtureScoreGrade grade, int points) =>
    FixtureScoreResult(
      fixture: FixtureRef(fixture),
      grade: grade,
      points: points,
    );

void main() {
  group('FixtureScoreGrade', () {
    test('wire tokens are stable and round-trip via tryParse', () {
      for (final grade in FixtureScoreGrade.values) {
        final parsed = FixtureScoreGrade.tryParse(grade.wireValue);
        expect((parsed as Ok<FixtureScoreGrade>).value, grade);
      }
    });

    test('rejects an unknown grade token', () {
      final result = FixtureScoreGrade.tryParse('almost');
      final error = (result as Err<FixtureScoreGrade>).error;
      expect(error.kind, ErrorKind.validation);
      expect(error.code, 'scoring.grade_unknown');
    });

    test('rejects a null grade token', () {
      final result = FixtureScoreGrade.tryParse(null);
      expect(
        (result as Err<FixtureScoreGrade>).error.code,
        'scoring.grade_unknown',
      );
    });
  });

  group('FixtureScoreResult equality', () {
    test('identical results compare equal and share a hashCode', () {
      final a = _fsr(_fixtureA, FixtureScoreGrade.exactScoreline, 5);
      final b = _fsr(_fixtureA, FixtureScoreGrade.exactScoreline, 5);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('a differing grade breaks equality', () {
      expect(
        _fsr(_fixtureA, FixtureScoreGrade.exactScoreline, 5),
        isNot(_fsr(_fixtureA, FixtureScoreGrade.correctOutcome, 5)),
      );
    });
  });

  group('RoundScore.fromGraded', () {
    test('sums points and preserves the graded order', () {
      final result = RoundScore.fromGraded(
        roundId: const RoundId(_round),
        participantId: const ParticipantId(_participant),
        rulesetVersion: 2,
        fixtureResults: [
          _fsr(_fixtureA, FixtureScoreGrade.exactScoreline, 5),
          _fsr(_fixtureB, FixtureScoreGrade.correctOutcome, 2),
        ],
      );
      final score = (result as Ok<RoundScore>).value;
      expect(score.totalPoints, 7);
      expect(score.rulesetVersion, 2);
      expect(score.fixtureResults.map((r) => r.fixture.value).toList(), [
        _fixtureA,
        _fixtureB,
      ]);
    });

    test('rejects an empty fixture set', () {
      final result = RoundScore.fromGraded(
        roundId: const RoundId(_round),
        participantId: const ParticipantId(_participant),
        rulesetVersion: 1,
        fixtureResults: const [],
      );
      final error = (result as Err<RoundScore>).error;
      expect(error.kind, ErrorKind.invariant);
      expect(error.code, 'scoring.no_fixtures_scored');
    });

    test('exposes an unmodifiable fixture list', () {
      final score =
          (RoundScore.fromGraded(
                    roundId: const RoundId(_round),
                    participantId: const ParticipantId(_participant),
                    rulesetVersion: 1,
                    fixtureResults: [
                      _fsr(_fixtureA, FixtureScoreGrade.incorrect, 0),
                    ],
                  )
                  as Ok<RoundScore>)
              .value;
      expect(
        () => score.fixtureResults.add(
          _fsr(_fixtureB, FixtureScoreGrade.incorrect, 0),
        ),
        throwsUnsupportedError,
      );
    });
  });

  group('RoundScore.fromStored', () {
    test('rehydrates without re-summation and is value-comparable', () {
      RoundScore stored() => RoundScore.fromStored(
        roundId: const RoundId(_round),
        participantId: const ParticipantId(_participant),
        rulesetVersion: 1,
        totalPoints: 7,
        fixtureResults: [
          _fsr(_fixtureA, FixtureScoreGrade.exactScoreline, 5),
          _fsr(_fixtureB, FixtureScoreGrade.correctOutcome, 2),
        ],
      );
      expect(stored(), stored());
      expect(stored().hashCode, stored().hashCode);
      expect(stored().totalPoints, 7);
    });

    test('a differing total breaks equality', () {
      final a = RoundScore.fromStored(
        roundId: const RoundId(_round),
        participantId: const ParticipantId(_participant),
        rulesetVersion: 1,
        totalPoints: 5,
        fixtureResults: [_fsr(_fixtureA, FixtureScoreGrade.exactScoreline, 5)],
      );
      final b = RoundScore.fromStored(
        roundId: const RoundId(_round),
        participantId: const ParticipantId(_participant),
        rulesetVersion: 1,
        totalPoints: 6,
        fixtureResults: [_fsr(_fixtureA, FixtureScoreGrade.exactScoreline, 5)],
      );
      expect(a, isNot(b));
    });
  });
}
