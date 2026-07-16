import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

const _fixtureA = '11111111-1111-1111-1111-111111111111';
const _fixtureB = '22222222-2222-2222-2222-222222222222';

FixtureScorePrediction _score({
  String fixture = _fixtureA,
  int home = 2,
  int away = 1,
}) =>
    (FixtureScorePrediction.create(
              fixture: FixtureRef(fixture),
              homeGoals: home,
              awayGoals: away,
            )
            as Ok<FixtureScorePrediction>)
        .value;

void main() {
  group('FixtureScorePrediction.create', () {
    test('builds a validated score behind the football seam', () {
      final score = _score();
      expect(score.fixture, const FixtureRef(_fixtureA));
      expect(score.homeGoals, 2);
      expect(score.awayGoals, 1);
    });

    test('accepts a goalless draw (zero is a valid, non-negative tally)', () {
      final score = _score(home: 0, away: 0);
      expect(score.homeGoals, 0);
      expect(score.awayGoals, 0);
    });

    test('accepts the ceiling scoreline exactly', () {
      final score = _score(
        home: FixtureScorePrediction.maxGoals,
        away: FixtureScorePrediction.maxGoals,
      );
      expect(score.homeGoals, FixtureScorePrediction.maxGoals);
      expect(score.awayGoals, FixtureScorePrediction.maxGoals);
    });

    test('rejects negative home goals', () {
      final result = FixtureScorePrediction.create(
        fixture: const FixtureRef(_fixtureA),
        homeGoals: -1,
        awayGoals: 0,
      );
      final error = (result as Err<FixtureScorePrediction>).error;
      expect(error.kind, ErrorKind.validation);
      expect(error.code, 'prediction.score_negative');
    });

    test('rejects negative away goals', () {
      final result = FixtureScorePrediction.create(
        fixture: const FixtureRef(_fixtureA),
        homeGoals: 0,
        awayGoals: -3,
      );
      final error = (result as Err<FixtureScorePrediction>).error;
      expect(error.kind, ErrorKind.validation);
      expect(error.code, 'prediction.score_negative');
    });

    test('rejects a home tally above the defensive ceiling', () {
      final result = FixtureScorePrediction.create(
        fixture: const FixtureRef(_fixtureA),
        homeGoals: FixtureScorePrediction.maxGoals + 1,
        awayGoals: 0,
      );
      final error = (result as Err<FixtureScorePrediction>).error;
      expect(error.kind, ErrorKind.validation);
      expect(error.code, 'prediction.score_out_of_range');
    });

    test('rejects an away tally above the defensive ceiling', () {
      final result = FixtureScorePrediction.create(
        fixture: const FixtureRef(_fixtureA),
        homeGoals: 0,
        awayGoals: FixtureScorePrediction.maxGoals + 1,
      );
      final error = (result as Err<FixtureScorePrediction>).error;
      expect(error.kind, ErrorKind.validation);
      expect(error.code, 'prediction.score_out_of_range');
    });
  });

  group('FixtureScorePrediction equality', () {
    test('identical scores compare equal and share a hashCode', () {
      expect(_score(), _score());
      expect(_score().hashCode, _score().hashCode);
    });

    test('a differing fixture breaks equality', () {
      expect(_score(fixture: _fixtureA), isNot(_score(fixture: _fixtureB)));
    });

    test('a differing scoreline breaks equality', () {
      expect(_score(home: 2, away: 1), isNot(_score(home: 1, away: 2)));
    });
  });
}
