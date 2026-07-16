import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import '../competition/fake_competition_repository.dart';
import '../competition/fakes.dart';
import 'fakes.dart';

const _round = '33333333-3333-3333-3333-333333333333';
const _season = '55555555-5555-5555-5555-555555555555';
const _f1 = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
const _p1 = '22222222-2222-2222-2222-222222222222';
const _partId = '66666666-6666-6666-6666-666666666666';
const _user = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee';
const _outsider = 'ffffffff-ffff-ffff-ffff-ffffffffffff';

RoundScore _seedScore() =>
    (RoundScore.fromGraded(
              roundId: const RoundId(_round),
              participantId: const ParticipantId(_p1),
              rulesetVersion: 1,
              fixtureResults: const [
                FixtureScoreResult(
                  fixture: FixtureRef(_f1),
                  grade: FixtureScoreGrade.exactScoreline,
                  points: 3,
                ),
              ],
            )
            as Ok<RoundScore>)
        .value;

void main() {
  late FakeCompetitionRepository competition;
  late FakeScoreRepository scores;
  late GetRoundScores useCase;

  void seedRound(RoundStatus status) {
    competition.seedRound(
      scoringRound(id: _round, seasonId: _season, status: status),
    );
  }

  void seedMembership() {
    competition.seedParticipant(
      scoringParticipant(id: _partId, seasonId: _season, userId: _user),
    );
  }

  setUp(() {
    competition = FakeCompetitionRepository();
    scores = FakeScoreRepository();
    useCase = GetRoundScores(
      competitionRepository: competition,
      scoreRepository: scores,
    );
  });

  test('a participant reads the scores of a scored round', () async {
    seedRound(RoundStatus.scored);
    seedMembership();
    await scores.saveRoundScores([_seedScore()]);
    final r = await useCase.call(
      principal: userPrincipal(_user),
      roundId: _round,
    );
    expect(r, isA<Ok<List<RoundScore>>>());
    expect((r as Ok<List<RoundScore>>).value.single.totalPoints, 3);
  });

  test('a locked (not yet scored) round is gated', () async {
    seedRound(RoundStatus.locked);
    seedMembership();
    final r = await useCase.call(
      principal: userPrincipal(_user),
      roundId: _round,
    );
    final err = (r as Err<List<RoundScore>>).error;
    expect(err.kind, ErrorKind.invariant);
    expect(err.code, 'scoring.round_not_scored');
  });

  test('an open round is gated too', () async {
    seedRound(RoundStatus.open);
    seedMembership();
    final r = await useCase.call(
      principal: userPrincipal(_user),
      roundId: _round,
    );
    expect((r as Err<List<RoundScore>>).error.code, 'scoring.round_not_scored');
  });

  test('a non-participant of the season is rejected', () async {
    seedRound(RoundStatus.scored);
    seedMembership();
    final r = await useCase.call(
      principal: userPrincipal(_outsider),
      roundId: _round,
    );
    final err = (r as Err<List<RoundScore>>).error;
    expect(err.kind, ErrorKind.authorization);
    expect(err.code, 'scoring.not_a_participant');
  });

  test('a missing round propagates the not-found invariant', () async {
    final r = await useCase.call(
      principal: userPrincipal(_user),
      roundId: _round,
    );
    expect(
      (r as Err<List<RoundScore>>).error.code,
      'competition.round_not_found',
    );
  });
}
