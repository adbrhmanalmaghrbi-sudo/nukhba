import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

const _fixtureA = '11111111-1111-1111-1111-111111111111';
const _fixtureB = '22222222-2222-2222-2222-222222222222';

FixtureResult _result({
  String fixture = _fixtureA,
  int home = 2,
  int away = 1,
}) =>
    (FixtureResult.create(
              fixture: FixtureRef(fixture),
              homeGoals: home,
              awayGoals: away,
            )
            as Ok<FixtureResult>)
        .value;

void main() {
  group('FixtureResult.create', () {
    test('builds a validated actual result behind the football seam', () {
      final result = _result();
      expect(result.fixture, const FixtureRef(_fixtureA));
      expect(result.homeGoals, 2);
      expect(result.awayGoals, 1);
    });

    test('accepts a goalless draw', () {
      final result = _result(home: 0, away: 0);
      expect(result.homeGoals, 0);
      expect(result.awayGoals, 0);
    });

    test('accepts the ceiling scoreline exactly', () {
      final result = _result(
        home: FixtureResult.maxGoals,
        away: FixtureResult.maxGoals,
      );
      expect(result.homeGoals, FixtureResult.maxGoals);
      expect(result.awayGoals, FixtureResult.maxGoals);
    });

    test('shares the defensive ceiling with a prediction', () {
      expect(FixtureResult.maxGoals, FixtureScorePrediction.maxGoals);
    });

    test('rejects negative home goals', () {
      final result = FixtureResult.create(
        fixture: const FixtureRef(_fixtureA),
        homeGoals: -1,
        awayGoals: 0,
      );
      final error = (result as Err<FixtureResult>).error;
      expect(error.kind, ErrorKind.validation);
      expect(error.code, 'scoring.result_negative');
    });

    test('rejects negative away goals', () {
      final result = FixtureResult.create(
        fixture: const FixtureRef(_fixtureA),
        homeGoals: 0,
        awayGoals: -2,
      );
      final error = (result as Err<FixtureResult>).error;
      expect(error.kind, ErrorKind.validation);
      expect(error.code, 'scoring.result_negative');
    });

    test('rejects a home tally above the ceiling', () {
      final result = FixtureResult.create(
        fixture: const FixtureRef(_fixtureA),
        homeGoals: FixtureResult.maxGoals + 1,
        awayGoals: 0,
      );
      final error = (result as Err<FixtureResult>).error;
      expect(error.kind, ErrorKind.validation);
      expect(error.code, 'scoring.result_out_of_range');
    });

    test('rejects an away tally above the ceiling', () {
      final result = FixtureResult.create(
        fixture: const FixtureRef(_fixtureA),
        homeGoals: 0,
        awayGoals: FixtureResult.maxGoals + 1,
      );
      final error = (result as Err<FixtureResult>).error;
      expect(error.kind, ErrorKind.validation);
      expect(error.code, 'scoring.result_out_of_range');
    });
  });

  group('FixtureResult.outcome', () {
    test('home win when home scores strictly more', () {
      expect(_result(home: 3, away: 1).outcome, MatchOutcome.homeWin);
    });

    test('away win when away scores strictly more', () {
      expect(_result(home: 0, away: 2).outcome, MatchOutcome.awayWin);
    });

    test('draw when the tallies are equal', () {
      expect(_result(home: 1, away: 1).outcome, MatchOutcome.draw);
    });
  });

  group('MatchOutcome.fromGoals', () {
    test('matches FixtureResult.outcome for every relation', () {
      expect(MatchOutcome.fromGoals(2, 0), MatchOutcome.homeWin);
      expect(MatchOutcome.fromGoals(0, 2), MatchOutcome.awayWin);
      expect(MatchOutcome.fromGoals(2, 2), MatchOutcome.draw);
    });
  });

  group('FixtureResult equality', () {
    test('identical results compare equal and share a hashCode', () {
      expect(_result(), _result());
      expect(_result().hashCode, _result().hashCode);
    });

    test('a differing fixture breaks equality', () {
      expect(_result(fixture: _fixtureA), isNot(_result(fixture: _fixtureB)));
    });

    test('a differing scoreline breaks equality', () {
      expect(_result(home: 2, away: 1), isNot(_result(home: 1, away: 2)));
    });
  });
}
