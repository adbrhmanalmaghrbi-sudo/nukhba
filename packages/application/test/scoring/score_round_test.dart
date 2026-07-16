import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import '../competition/fake_competition_repository.dart';
import '../competition/fakes.dart';
import '../prediction/fake_prediction_repository.dart';
import 'fakes.dart';

const _round = '33333333-3333-3333-3333-333333333333';
const _season = '55555555-5555-5555-5555-555555555555';
const _f1 = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
const _f2 = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
const _p1 = '22222222-2222-2222-2222-222222222222';
const _p2 = '77777777-7777-7777-7777-777777777777';
const _pred1 = '11111111-1111-1111-1111-111111111111';
const _pred2 = '99999999-9999-9999-9999-999999999999';
const _admin = 'dddddddd-dddd-dddd-dddd-dddddddddddd';
const _user = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee';

void main() {
  late FakeCompetitionRepository competition;
  late FakePredictionRepository predictions;
  late FakeFixtureResultRepository results;
  late FakeScoreRepository scores;
  late ScoreRound useCase;

  void wire({RoundStatus status = RoundStatus.locked}) {
    competition.seedRound(
      scoringRound(id: _round, seasonId: _season, status: status),
    );
    predictions.seedRoundFixtures(const RoundId(_round), [
      scoringLink(roundId: _round, fixtureId: _f1, order: 0),
      scoringLink(roundId: _round, fixtureId: _f2, order: 1),
    ]);
    // Actual results: f1 = 2-1 (home win), f2 = 0-0 (draw).
    results
      ..seed(scoringResult(fixtureId: _f1, home: 2, away: 1))
      ..seed(scoringResult(fixtureId: _f2, home: 0, away: 0));
  }

  setUp(() {
    competition = FakeCompetitionRepository();
    predictions = FakePredictionRepository();
    results = FakeFixtureResultRepository();
    scores = FakeScoreRepository();
    useCase = ScoreRound(
      competitionRepository: competition,
      predictionRepository: predictions,
      resultRepository: results,
      scoreRepository: scores,
    );
  });

  test('grades exact / outcome / incorrect and sums the total', () async {
    wire();
    // p1: f1 exact (2-1), f2 outcome (1-1 draw predicted → draw actual).
    predictions.seedPrediction(
      scoringPrediction(
        id: _pred1,
        roundId: _round,
        participantId: _p1,
        scores: [(_f1, 2, 1), (_f2, 1, 1)],
      ),
      DateTime.utc(2026, 7, 10, 12),
    );
    // p2: f1 incorrect (0-2 away win vs home win), f2 exact (0-0).
    predictions.seedPrediction(
      scoringPrediction(
        id: _pred2,
        roundId: _round,
        participantId: _p2,
        scores: [(_f1, 0, 2), (_f2, 0, 0)],
      ),
      DateTime.utc(2026, 7, 10, 13),
    );

    final r = await useCase.call(
      principal: adminPrincipal(_admin),
      roundId: _round,
    );
    expect(r, isA<Ok<List<RoundScore>>>());
    final out = (r as Ok<List<RoundScore>>).value;
    expect(out, hasLength(2));

    final byParticipant = {for (final s in out) s.participantId.value: s};
    // p1: exact(3) + outcome(1) = 4.
    expect(byParticipant[_p1]!.totalPoints, 4);
    expect(
      byParticipant[_p1]!.fixtureResults[0].grade,
      FixtureScoreGrade.exactScoreline,
    );
    expect(
      byParticipant[_p1]!.fixtureResults[1].grade,
      FixtureScoreGrade.correctOutcome,
    );
    // p2: incorrect(0) + exact(3) = 3.
    expect(byParticipant[_p2]!.totalPoints, 3);
    expect(
      byParticipant[_p2]!.fixtureResults[0].grade,
      FixtureScoreGrade.incorrect,
    );
    // Ruleset version is carried through.
    expect(byParticipant[_p1]!.rulesetVersion, 1);
  });

  test('preserves the prediction fixture order in the breakdown', () async {
    wire();
    predictions.seedPrediction(
      scoringPrediction(
        id: _pred1,
        roundId: _round,
        participantId: _p1,
        scores: [(_f2, 0, 0), (_f1, 2, 1)],
      ),
      DateTime.utc(2026, 7, 10, 12),
    );
    final r = await useCase.call(
      principal: adminPrincipal(_admin),
      roundId: _round,
    );
    final breakdown = (r as Ok<List<RoundScore>>).value.single.fixtureResults;
    expect(breakdown[0].fixture.value, _f2);
    expect(breakdown[1].fixture.value, _f1);
  });

  test('a non-admin caller is rejected (authorization)', () async {
    wire();
    final r = await useCase.call(
      principal: userPrincipal(_user),
      roundId: _round,
    );
    expect((r as Err<List<RoundScore>>).error.kind, ErrorKind.authorization);
    expect(scores.count, 0);
  });

  test('an open round cannot be scored', () async {
    wire(status: RoundStatus.open);
    final r = await useCase.call(
      principal: adminPrincipal(_admin),
      roundId: _round,
    );
    final err = (r as Err<List<RoundScore>>).error;
    expect(err.kind, ErrorKind.invariant);
    expect(err.code, 'scoring.round_not_locked');
    expect(scores.count, 0);
  });

  test('scoring transitions the round locked → scored', () async {
    wire();
    predictions.seedPrediction(
      scoringPrediction(
        id: _pred1,
        roundId: _round,
        participantId: _p1,
        scores: [(_f1, 2, 1), (_f2, 0, 0)],
      ),
      DateTime.utc(2026, 7, 10, 12),
    );
    await useCase.call(principal: adminPrincipal(_admin), roundId: _round);
    expect(competition.round(_round)!.status, RoundStatus.scored);
  });

  test(
    're-scoring an already-scored round is idempotent (no dup, no conflict)',
    () async {
      wire();
      predictions.seedPrediction(
        scoringPrediction(
          id: _pred1,
          roundId: _round,
          participantId: _p1,
          scores: [(_f1, 2, 1), (_f2, 0, 0)],
        ),
        DateTime.utc(2026, 7, 10, 12),
      );
      // First score: locked → scored.
      final first = await useCase.call(
        principal: adminPrincipal(_admin),
        roundId: _round,
      );
      expect(first, isA<Ok<List<RoundScore>>>());
      expect(scores.count, 1);

      // Second score on the now-`scored` round: recomputes and re-persists the
      // identical score, reports success, no transition-conflict, still one row.
      final second = await useCase.call(
        principal: adminPrincipal(_admin),
        roundId: _round,
      );
      expect(second, isA<Ok<List<RoundScore>>>());
      expect(scores.count, 1);
      expect(
        (second as Ok<List<RoundScore>>).value.single.totalPoints,
        (first as Ok<List<RoundScore>>).value.single.totalPoints,
      );
    },
  );

  test('a missing actual result blocks scoring (results incomplete)', () async {
    wire();
    // Drop f2's result.
    results = FakeFixtureResultRepository()
      ..seed(scoringResult(fixtureId: _f1, home: 2, away: 1));
    useCase = ScoreRound(
      competitionRepository: competition,
      predictionRepository: predictions,
      resultRepository: results,
      scoreRepository: scores,
    );
    predictions.seedPrediction(
      scoringPrediction(
        id: _pred1,
        roundId: _round,
        participantId: _p1,
        scores: [(_f1, 2, 1), (_f2, 0, 0)],
      ),
      DateTime.utc(2026, 7, 10, 12),
    );
    final r = await useCase.call(
      principal: adminPrincipal(_admin),
      roundId: _round,
    );
    final err = (r as Err<List<RoundScore>>).error;
    expect(err.code, 'scoring.results_incomplete');
    expect(scores.count, 0);
  });

  test('a round with no fixtures cannot be scored', () async {
    competition.seedRound(
      scoringRound(id: _round, seasonId: _season, status: RoundStatus.locked),
    );
    final r = await useCase.call(
      principal: adminPrincipal(_admin),
      roundId: _round,
    );
    expect(
      (r as Err<List<RoundScore>>).error.code,
      'scoring.round_has_no_fixtures',
    );
  });

  test('a round with no predictions scores to an empty result set', () async {
    wire();
    final r = await useCase.call(
      principal: adminPrincipal(_admin),
      roundId: _round,
    );
    expect((r as Ok<List<RoundScore>>).value, isEmpty);
    // The round still transitions to scored (there was nothing to score).
    expect(competition.round(_round)!.status, RoundStatus.scored);
  });

  test(
    'a corrupt frozen ruleset is a typed failure, never a silent zero',
    () async {
      competition.seedRound(
        scoringRound(
          id: _round,
          seasonId: _season,
          status: RoundStatus.locked,
          // Non-monotonic: incorrect > exact.
          ruleset: scoringSnapshot(exact: 0, outcome: 0, incorrect: 5),
        ),
      );
      predictions.seedRoundFixtures(const RoundId(_round), [
        scoringLink(roundId: _round, fixtureId: _f1, order: 0),
      ]);
      results.seed(scoringResult(fixtureId: _f1, home: 1, away: 0));
      final r = await useCase.call(
        principal: adminPrincipal(_admin),
        roundId: _round,
      );
      expect(
        (r as Err<List<RoundScore>>).error.code,
        'scoring.ruleset_non_monotonic',
      );
      expect(scores.count, 0);
    },
  );

  test('a transient prediction-store failure propagates', () async {
    wire();
    predictions.failNextWith(
      const AppError.transient('db.down', 'unavailable'),
    );
    final r = await useCase.call(
      principal: adminPrincipal(_admin),
      roundId: _round,
    );
    expect((r as Err<List<RoundScore>>).error.kind, ErrorKind.transient);
  });
}
