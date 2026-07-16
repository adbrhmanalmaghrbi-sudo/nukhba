import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import '../competition/fake_competition_repository.dart';
import '../competition/fakes.dart';
import 'fake_prediction_repository.dart';

const _userId = '11111111-1111-1111-1111-111111111111';
const _seasonId = '33333333-3333-3333-3333-333333333333';
const _roundId = '44444444-4444-4444-4444-444444444444';
const _participantId = '55555555-5555-5555-5555-555555555555';
const _predictionId = '66666666-6666-6666-6666-666666666666';
const _fixtureA = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';

final _now = DateTime.utc(2026, 8, 1, 12);

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
  return (open.transitionTo(status) as Ok<Round>).value;
}

Participant _participant() =>
    (Participant.join(
              id: const ParticipantId(_participantId),
              seasonId: const SeasonId(_seasonId),
              userId: const UserId(_userId),
              joinedAt: _now,
            )
            as Ok<Participant>)
        .value;

Prediction _prediction() =>
    (Prediction.submit(
              id: const PredictionId(_predictionId),
              roundId: const RoundId(_roundId),
              participantId: const ParticipantId(_participantId),
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
  late GetMyPrediction useCase;

  setUp(() {
    predictions = FakePredictionRepository();
    competition = FakeCompetitionRepository()
      ..seedRound(_round())
      ..seedParticipant(_participant());
    useCase = GetMyPrediction(
      predictionRepository: predictions,
      competitionRepository: competition,
    );
  });

  test(
    'returns the caller own prediction (self-read allowed at any status)',
    () async {
      predictions.seedPrediction(_prediction(), _now);

      final result = await useCase(
        principal: userPrincipal(_userId),
        roundId: _roundId,
      );

      final view = (result as Ok<PredictionView?>).value;
      expect(view, isNotNull);
      expect(view!.prediction.id, const PredictionId(_predictionId));
      expect(view.submittedAt, _now);
    },
  );

  test(
    'returns null when the caller has joined but not yet predicted',
    () async {
      final result = await useCase(
        principal: userPrincipal(_userId),
        roundId: _roundId,
      );

      expect((result as Ok<PredictionView?>).value, isNull);
    },
  );

  test('returns null for a non-participant (no data leak of others)', () async {
    competition = FakeCompetitionRepository()..seedRound(_round());
    useCase = GetMyPrediction(
      predictionRepository: predictions,
      competitionRepository: competition,
    );

    final result = await useCase(
      principal: userPrincipal(_userId),
      roundId: _roundId,
    );

    expect((result as Ok<PredictionView?>).value, isNull);
  });

  test('a missing round is an invariant precondition failure', () async {
    competition = FakeCompetitionRepository();
    useCase = GetMyPrediction(
      predictionRepository: predictions,
      competitionRepository: competition,
    );

    final result = await useCase(
      principal: userPrincipal(_userId),
      roundId: _roundId,
    );

    final error = (result as Err<PredictionView?>).error;
    expect(error.kind, ErrorKind.invariant);
    expect(error.code, 'competition.round_not_found');
  });
}
