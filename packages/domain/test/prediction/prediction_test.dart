import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

const _predictionId = '11111111-1111-1111-1111-111111111111';
const _roundId = '22222222-2222-2222-2222-222222222222';
const _participantId = '33333333-3333-3333-3333-333333333333';
const _fixtureA = '44444444-4444-4444-4444-444444444444';
const _fixtureB = '55555555-5555-5555-5555-555555555555';

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

Result<Prediction> _submit({
  RoundStatus status = RoundStatus.open,
  List<FixtureScorePrediction>? scores,
}) => Prediction.submit(
  id: const PredictionId(_predictionId),
  roundId: const RoundId(_roundId),
  participantId: const ParticipantId(_participantId),
  roundStatus: status,
  scores: scores ?? [_score()],
);

Prediction _open({List<FixtureScorePrediction>? scores}) =>
    (_submit(scores: scores) as Ok<Prediction>).value;

void main() {
  group('Prediction.submit', () {
    test('names round + participant by id and freezes the scores', () {
      final prediction = _open(scores: [_score(fixture: _fixtureA)]);
      expect(prediction.id, const PredictionId(_predictionId));
      expect(prediction.roundId, const RoundId(_roundId));
      expect(prediction.participantId, const ParticipantId(_participantId));
      expect(prediction.scores, hasLength(1));
      expect(prediction.scores.single.fixture, const FixtureRef(_fixtureA));
    });

    test('exposes scores as an unmodifiable list (aggregate owns them)', () {
      final prediction = _open();
      expect(
        () => prediction.scores.add(_score(fixture: _fixtureB)),
        throwsUnsupportedError,
      );
    });

    test('accepts a multi-fixture forecast with distinct fixtures', () {
      final prediction = _open(
        scores: [
          _score(fixture: _fixtureA),
          _score(fixture: _fixtureB),
        ],
      );
      expect(prediction.scores, hasLength(2));
    });

    test('rejects submission once the round is locked (Axiom 6)', () {
      final result = _submit(status: RoundStatus.locked);
      final error = (result as Err<Prediction>).error;
      expect(error.kind, ErrorKind.invariant);
      expect(error.code, 'prediction.round_not_open');
    });

    test('rejects submission once the round is scored', () {
      final result = _submit(status: RoundStatus.scored);
      final error = (result as Err<Prediction>).error;
      expect(error.kind, ErrorKind.invariant);
      expect(error.code, 'prediction.round_not_open');
    });

    test('rejects an empty forecast', () {
      final result = _submit(scores: const []);
      final error = (result as Err<Prediction>).error;
      expect(error.kind, ErrorKind.validation);
      expect(error.code, 'prediction.no_scores');
    });

    test('rejects a duplicate fixture within the forecast', () {
      final result = _submit(
        scores: [
          _score(fixture: _fixtureA, home: 2, away: 1),
          _score(fixture: _fixtureA, home: 0, away: 0),
        ],
      );
      final error = (result as Err<Prediction>).error;
      expect(error.kind, ErrorKind.validation);
      expect(error.code, 'prediction.duplicate_fixture');
    });
  });

  group('Prediction.amend', () {
    test('preserves identity while revising the forecast (one per round)', () {
      final original = _open(scores: [_score(fixture: _fixtureA)]);
      final result = original.amend(
        roundStatus: RoundStatus.open,
        scores: [_score(fixture: _fixtureB, home: 3, away: 3)],
      );
      final amended = (result as Ok<Prediction>).value;
      // Same aggregate identity — never a second row (Axiom 4).
      expect(amended.id, original.id);
      expect(amended.roundId, original.roundId);
      expect(amended.participantId, original.participantId);
      // Revised forecast.
      expect(amended.scores.single.fixture, const FixtureRef(_fixtureB));
      expect(amended.scores.single.homeGoals, 3);
    });

    test('rejects amendment once the round is locked', () {
      final result = _open().amend(
        roundStatus: RoundStatus.locked,
        scores: [_score()],
      );
      final error = (result as Err<Prediction>).error;
      expect(error.kind, ErrorKind.invariant);
      expect(error.code, 'prediction.round_not_open');
    });

    test('rejects an empty amended forecast', () {
      final result = _open().amend(
        roundStatus: RoundStatus.open,
        scores: const [],
      );
      final error = (result as Err<Prediction>).error;
      expect(error.kind, ErrorKind.validation);
      expect(error.code, 'prediction.no_scores');
    });

    test('rejects a duplicate fixture in the amended forecast', () {
      final result = _open().amend(
        roundStatus: RoundStatus.open,
        scores: [
          _score(fixture: _fixtureB, home: 1, away: 0),
          _score(fixture: _fixtureB, home: 2, away: 2),
        ],
      );
      final error = (result as Err<Prediction>).error;
      expect(error.kind, ErrorKind.validation);
      expect(error.code, 'prediction.duplicate_fixture');
    });

    test('the amended copy is also unmodifiable', () {
      final amended =
          (_open().amend(
                    roundStatus: RoundStatus.open,
                    scores: [_score(fixture: _fixtureA)],
                  )
                  as Ok<Prediction>)
              .value;
      expect(
        () => amended.scores.add(_score(fixture: _fixtureB)),
        throwsUnsupportedError,
      );
    });
  });

  group('Prediction equality', () {
    test('identical predictions compare equal and share a hashCode', () {
      expect(_open(), _open());
      expect(_open().hashCode, _open().hashCode);
    });

    test('a differing scoreline breaks equality', () {
      final a = _open(scores: [_score(fixture: _fixtureA, home: 2, away: 1)]);
      final b = _open(scores: [_score(fixture: _fixtureA, home: 1, away: 2)]);
      expect(a, isNot(b));
    });

    test('a differing fixture set breaks equality', () {
      final a = _open(scores: [_score(fixture: _fixtureA)]);
      final b = _open(
        scores: [
          _score(fixture: _fixtureA),
          _score(fixture: _fixtureB),
        ],
      );
      expect(a, isNot(b));
    });

    test('score ordering is significant to equality', () {
      final a = _open(
        scores: [
          _score(fixture: _fixtureA),
          _score(fixture: _fixtureB),
        ],
      );
      final b = _open(
        scores: [
          _score(fixture: _fixtureB),
          _score(fixture: _fixtureA),
        ],
      );
      expect(a, isNot(b));
    });
  });
}
