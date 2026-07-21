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
const _fixtureB = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';

final _now = DateTime.utc(2026, 8, 1, 12);
final _later = DateTime.utc(2026, 8, 1, 13);

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

RoundFixture _link(String fixture, int order) =>
    (RoundFixture.create(
              roundId: const RoundId(_roundId),
              fixture: FixtureRef(fixture),
              displayOrder: order,
            )
            as Ok<RoundFixture>)
        .value;

void main() {
  late FakePredictionRepository predictions;
  late FakeCompetitionRepository competition;
  late SubmitPrediction useCase;

  setUp(() {
    predictions = FakePredictionRepository();
    competition = FakeCompetitionRepository();
    useCase = SubmitPrediction(
      predictionRepository: predictions,
      competitionRepository: competition,
      idGenerator: FakeIdGenerator([_predictionId]),
      clock: FixedClock(_now),
    );

    competition.seedRound(_round());
    competition.seedParticipant(_participant());
    predictions.seedRoundFixtures(const RoundId(_roundId), [
      _link(_fixtureA, 0),
      _link(_fixtureB, 1),
    ]);
  });

  List<FixtureScoreInput> completeScores() => const [
    FixtureScoreInput(fixtureId: _fixtureA, homeGoals: 2, awayGoals: 1),
    FixtureScoreInput(fixtureId: _fixtureB, homeGoals: 0, awayGoals: 0),
  ];

  test('a first complete submission inserts one prediction', () async {
    final result = await useCase(
      principal: userPrincipal(_userId),
      roundId: _roundId,
      scores: completeScores(),
    );

    final view = (result as Ok<PredictionView>).value;
    final prediction = view.prediction;
    expect(prediction.id, const PredictionId(_predictionId));
    expect(prediction.roundId, const RoundId(_roundId));
    expect(prediction.participantId, const ParticipantId(_participantId));
    expect(prediction.scores, hasLength(2));
    // The view echoes the exact clock instant the use-case stamped.
    expect(view.submittedAt, _now);
    expect(predictions.count, 1);
    expect(
      predictions.submittedAtOf(
        const RoundId(_roundId),
        const ParticipantId(_participantId),
      ),
      _now,
    );
  });

  test(
    're-submission amends in place (idempotent: still one row, new time)',
    () async {
      await useCase(
        principal: userPrincipal(_userId),
        roundId: _roundId,
        scores: completeScores(),
      );

      // Advance the clock and re-submit different scores.
      useCase = SubmitPrediction(
        predictionRepository: predictions,
        competitionRepository: competition,
        idGenerator: FakeIdGenerator([_predictionId]),
        clock: FixedClock(_later),
      );
      final second = await useCase(
        principal: userPrincipal(_userId),
        roundId: _roundId,
        scores: const [
          FixtureScoreInput(fixtureId: _fixtureA, homeGoals: 3, awayGoals: 3),
          FixtureScoreInput(fixtureId: _fixtureB, homeGoals: 1, awayGoals: 2),
        ],
      );

      final amendedView = (second as Ok<PredictionView>).value;
      final amended = amendedView.prediction;
      expect(
        amended.id,
        const PredictionId(_predictionId),
      ); // identity preserved
      expect(amended.scores.first.homeGoals, 3);
      expect(amendedView.submittedAt, _later); // refreshed to the amend instant
      expect(predictions.count, 1); // never a second row (Axiom 4)
      expect(
        predictions.submittedAtOf(
          const RoundId(_roundId),
          const ParticipantId(_participantId),
        ),
        _later,
      );
    },
  );

  test('submission after lock is rejected (Axiom 6, round not open)', () async {
    competition.seedRound(_round(status: RoundStatus.locked));

    final result = await useCase(
      principal: userPrincipal(_userId),
      roundId: _roundId,
      scores: completeScores(),
    );

    final error = (result as Err<PredictionView>).error;
    expect(error.kind, ErrorKind.invariant);
    expect(error.code, 'prediction.round_not_open');
    expect(predictions.count, 0);
  });

  test('a fixture not linked to the round is rejected', () async {
    final result = await useCase(
      principal: userPrincipal(_userId),
      roundId: _roundId,
      scores: const [
        FixtureScoreInput(fixtureId: _fixtureA, homeGoals: 1, awayGoals: 0),
        FixtureScoreInput(
          fixtureId: 'cccccccc-cccc-cccc-cccc-cccccccccccc',
          homeGoals: 0,
          awayGoals: 0,
        ),
      ],
    );

    final error = (result as Err<PredictionView>).error;
    expect(error.kind, ErrorKind.validation);
    expect(error.code, 'prediction.fixture_not_in_round');
  });

  test('a partial forecast (missing a fixture) is rejected', () async {
    final result = await useCase(
      principal: userPrincipal(_userId),
      roundId: _roundId,
      scores: const [
        FixtureScoreInput(fixtureId: _fixtureA, homeGoals: 1, awayGoals: 0),
      ],
    );

    final error = (result as Err<PredictionView>).error;
    expect(error.kind, ErrorKind.validation);
    expect(error.code, 'prediction.incomplete_forecast');
  });

  test(
    'a duplicate fixture (which shrinks the covered set) is rejected',
    () async {
      final result = await useCase(
        principal: userPrincipal(_userId),
        roundId: _roundId,
        scores: const [
          FixtureScoreInput(fixtureId: _fixtureA, homeGoals: 1, awayGoals: 0),
          FixtureScoreInput(fixtureId: _fixtureA, homeGoals: 2, awayGoals: 0),
        ],
      );

      final error = (result as Err<PredictionView>).error;
      expect(error.kind, ErrorKind.validation);
      expect(error.code, 'prediction.incomplete_forecast');
    },
  );

  test('a non-participant of the season is rejected as an invariant', () async {
    competition = FakeCompetitionRepository()..seedRound(_round());
    predictions.seedRoundFixtures(const RoundId(_roundId), [
      _link(_fixtureA, 0),
      _link(_fixtureB, 1),
    ]);
    useCase = SubmitPrediction(
      predictionRepository: predictions,
      competitionRepository: competition,
      idGenerator: FakeIdGenerator([_predictionId]),
      clock: FixedClock(_now),
    );

    final result = await useCase(
      principal: userPrincipal(_userId),
      roundId: _roundId,
      scores: completeScores(),
    );

    final error = (result as Err<PredictionView>).error;
    expect(error.kind, ErrorKind.invariant);
    expect(error.code, 'prediction.not_a_participant');
  });

  test(
    'an out-of-range score is rejected by the domain value object',
    () async {
      final result = await useCase(
        principal: userPrincipal(_userId),
        roundId: _roundId,
        scores: const [
          FixtureScoreInput(fixtureId: _fixtureA, homeGoals: 100, awayGoals: 0),
          FixtureScoreInput(fixtureId: _fixtureB, homeGoals: 0, awayGoals: 0),
        ],
      );

      final error = (result as Err<PredictionView>).error;
      expect(error.kind, ErrorKind.validation);
      expect(error.code, 'prediction.score_out_of_range');
    },
  );

  test('a round with no fixtures cannot be predicted', () async {
    predictions.seedRoundFixtures(const RoundId(_roundId), const []);

    final result = await useCase(
      principal: userPrincipal(_userId),
      roundId: _roundId,
      scores: completeScores(),
    );

    final error = (result as Err<PredictionView>).error;
    expect(error.kind, ErrorKind.invariant);
    expect(error.code, 'prediction.round_has_no_fixtures');
  });

  test(
    'a concurrent duplicate insert converges by amending (idempotent)',
    () async {
      // A rival writer's row (the race winner) lands at save time; the pre-read
      // missed it, so the use-case inserts, loses on the unique violation, then
      // re-reads and amends the winner in place.
      final winner =
          (Prediction.submit(
                    id: const PredictionId(_predictionId),
                    roundId: const RoundId(_roundId),
                    participantId: const ParticipantId(_participantId),
                    roundStatus: RoundStatus.open,
                    scores: [
                      (FixtureScorePrediction.create(
                                fixture: const FixtureRef(_fixtureA),
                                homeGoals: 9,
                                awayGoals: 9,
                              )
                              as Ok<FixtureScorePrediction>)
                          .value,
                      (FixtureScorePrediction.create(
                                fixture: const FixtureRef(_fixtureB),
                                homeGoals: 9,
                                awayGoals: 9,
                              )
                              as Ok<FixtureScorePrediction>)
                          .value,
                    ],
                  )
                  as Ok<Prediction>)
              .value;
      predictions.armSaveRace(winner, _now);

      useCase = SubmitPrediction(
        predictionRepository: predictions,
        competitionRepository: competition,
        idGenerator: FakeIdGenerator([_predictionId]),
        clock: FixedClock(_later),
      );

      final result = await useCase(
        principal: userPrincipal(_userId),
        roundId: _roundId,
        scores: completeScores(),
      );

      final prediction = (result as Ok<PredictionView>).value.prediction;
      expect(prediction.id, const PredictionId(_predictionId));
      expect(prediction.scores.first.homeGoals, 2); // amended to the new scores
      expect(predictions.count, 1); // still exactly one row
    },
  );

  test('a transient repository fault is propagated unchanged', () async {
    // The round load hits a transient DB fault; the use-case must surface it
    // as-is rather than masking it as a business error.
    competition.failNextWith(const AppError.transient('db.down', 'transient'));

    final result = await useCase(
      principal: userPrincipal(_userId),
      roundId: _roundId,
      scores: completeScores(),
    );

    final error = (result as Err<PredictionView>).error;
    expect(error.kind, ErrorKind.transient);
    expect(error.code, 'db.down');
  });

  test('a malformed round id is a validation error', () async {
    final result = await useCase(
      principal: userPrincipal(_userId),
      roundId: 'not-a-uuid',
      scores: completeScores(),
    );

    final error = (result as Err<PredictionView>).error;
    expect(error.kind, ErrorKind.validation);
    expect(error.code, 'competition.round_id_malformed');
  });
}
