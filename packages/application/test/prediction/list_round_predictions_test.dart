import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import '../competition/fake_competition_repository.dart';
import '../competition/fakes.dart';
import 'fake_prediction_repository.dart';

const _userId = '11111111-1111-1111-1111-111111111111';
const _otherUserId = '77777777-7777-7777-7777-777777777777';
const _seasonId = '33333333-3333-3333-3333-333333333333';
const _roundId = '44444444-4444-4444-4444-444444444444';
const _participantId = '55555555-5555-5555-5555-555555555555';
const _otherParticipantId = '88888888-8888-8888-8888-888888888888';
const _predictionId = '66666666-6666-6666-6666-666666666666';
const _otherPredictionId = '99999999-9999-9999-9999-999999999999';
const _fixtureA = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';

final _early = DateTime.utc(2026, 8, 1, 12);
final _late = DateTime.utc(2026, 8, 1, 13);

Round _round({RoundStatus status = RoundStatus.open}) {
  final open =
      (Round.open(
                id: const RoundId(_roundId),
                seasonId: const SeasonId(_seasonId),
                sequence: 1,
                predictionDeadline: DateTime.utc(2026, 8, 2),
                ruleset: testSnapshot(),
              )
              as Ok<Round>)
          .value;
  if (status == RoundStatus.open) return open;
  final locked = (open.transitionTo(RoundStatus.locked) as Ok<Round>).value;
  if (status == RoundStatus.locked) return locked;
  // scored is reached only via locked (linear lifecycle open→locked→scored).
  return (locked.transitionTo(RoundStatus.scored) as Ok<Round>).value;
}

Participant _participant(String id, String userId) =>
    (Participant.join(
              id: ParticipantId(id),
              seasonId: const SeasonId(_seasonId),
              userId: UserId(userId),
              joinedAt: _early,
            )
            as Ok<Participant>)
        .value;

Prediction _prediction(String id, String participantId) =>
    (Prediction.submit(
              id: PredictionId(id),
              roundId: const RoundId(_roundId),
              participantId: ParticipantId(participantId),
              roundStatus: RoundStatus.open,
              scores: [
                (FixtureScorePrediction.create(
                          fixture: const FixtureRef(_fixtureA),
                          homeGoals: 1,
                          awayGoals: 0,
                        )
                        as Ok<FixtureScorePrediction>)
                    .value,
              ],
            )
            as Ok<Prediction>)
        .value;

void main() {
  late FakePredictionRepository predictions;
  late FakeCompetitionRepository competition;
  late ListRoundPredictions useCase;

  setUp(() {
    predictions = FakePredictionRepository();
    competition = FakeCompetitionRepository()
      ..seedParticipant(_participant(_participantId, _userId));
    useCase = ListRoundPredictions(
      predictionRepository: predictions,
      competitionRepository: competition,
    );
  });

  test(
    'lists all predictions once the round is locked, stably ordered',
    () async {
      competition.seedRound(_round(status: RoundStatus.locked));
      // Seed out of time order; expect ascending by submittedAt.
      predictions
        ..seedPrediction(
          _prediction(_otherPredictionId, _otherParticipantId),
          _late,
        )
        ..seedPrediction(_prediction(_predictionId, _participantId), _early);

      final result = await useCase(
        principal: userPrincipal(_userId),
        roundId: _roundId,
      );

      final list = (result as Ok<List<PredictionView>>).value;
      expect(list, hasLength(2));
      // earlier first, and each view carries its stored submission instant
      expect(list.first.prediction.id, const PredictionId(_predictionId));
      expect(list.first.submittedAt, _early);
      expect(list.last.prediction.id, const PredictionId(_otherPredictionId));
      expect(list.last.submittedAt, _late);
    },
  );

  test(
    'rejects listing while the round is still open (fair-play gate)',
    () async {
      competition.seedRound(_round());
      predictions.seedPrediction(
        _prediction(_predictionId, _participantId),
        _early,
      );

      final result = await useCase(
        principal: userPrincipal(_userId),
        roundId: _roundId,
      );

      final error = (result as Err<List<PredictionView>>).error;
      expect(error.kind, ErrorKind.authorization);
      expect(error.code, 'prediction.round_not_locked');
    },
  );

  test('rejects a non-participant even for a locked round', () async {
    competition = FakeCompetitionRepository()
      ..seedRound(_round(status: RoundStatus.locked));
    useCase = ListRoundPredictions(
      predictionRepository: predictions,
      competitionRepository: competition,
    );

    final result = await useCase(
      principal: userPrincipal(_userId),
      roundId: _roundId,
    );

    final error = (result as Err<List<PredictionView>>).error;
    expect(error.kind, ErrorKind.authorization);
    expect(error.code, 'prediction.not_a_participant');
  });

  test('a scored round is also visible (past the open gate)', () async {
    competition.seedRound(_round(status: RoundStatus.scored));
    predictions.seedPrediction(
      _prediction(_predictionId, _participantId),
      _early,
    );

    final result = await useCase(
      principal: userPrincipal(_userId),
      roundId: _roundId,
    );

    expect((result as Ok<List<PredictionView>>).value, hasLength(1));
  });

  test('a missing round is an invariant precondition failure', () async {
    competition = FakeCompetitionRepository();
    useCase = ListRoundPredictions(
      predictionRepository: predictions,
      competitionRepository: competition,
    );

    final result = await useCase(
      principal: userPrincipal(_userId),
      roundId: _roundId,
    );

    final error = (result as Err<List<PredictionView>>).error;
    expect(error.kind, ErrorKind.invariant);
    expect(error.code, 'competition.round_not_found');
  });
}
