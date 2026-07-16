import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import '../competition/fake_competition_repository.dart';
import 'fakes.dart';

const _season = '11111111-1111-1111-1111-111111111111';
const _memberUser = 'aaaaaaaa-0000-0000-0000-000000000001';
const _outsiderUser = 'bbbbbbbb-0000-0000-0000-000000000002';

const _pA = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
const _pB = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
const _pC = 'cccccccc-cccc-cccc-cccc-cccccccccccc';

({
  GetSeasonLeaderboard useCase,
  FakeLeaderboardRepository leaderboard,
  FakeCompetitionRepository competition,
})
_harness() {
  final leaderboard = FakeLeaderboardRepository();
  final competition = FakeCompetitionRepository();
  final useCase = GetSeasonLeaderboard(
    leaderboardRepository: leaderboard,
    competitionRepository: competition,
  );
  return (useCase: useCase, leaderboard: leaderboard, competition: competition);
}

/// Enrols [_memberUser] in [_season] so the membership gate passes.
void _enrolMember(FakeCompetitionRepository competition) {
  competition.seedParticipant(
    boardParticipant(
      id: '00000000-0000-0000-0000-0000000000aa',
      seasonId: _season,
      userId: _memberUser,
    ),
  );
}

void main() {
  group('GetSeasonLeaderboard — authorization / membership', () {
    test('a non-member is refused leaderboard.not_a_participant', () async {
      final h = _harness();
      // No participant seeded for the outsider.
      final result = await h.useCase.call(
        principal: principalUser(userId: _outsiderUser),
        seasonId: _season,
      );
      final error = (result as Err<SeasonLeaderboard>).error;
      expect(error.code, 'leaderboard.not_a_participant');
      expect(error.kind, ErrorKind.authorization);
    });

    test(
      'an unknown season is refused identically (no existence oracle)',
      () async {
        final h = _harness();
        final result = await h.useCase.call(
          principal: principalUser(userId: _memberUser),
          seasonId: _season, // member of nothing → treated as non-member
        );
        expect(
          (result as Err<SeasonLeaderboard>).error.code,
          'leaderboard.not_a_participant',
        );
      },
    );

    test('a malformed season id is a validation error', () async {
      final h = _harness();
      final result = await h.useCase.call(
        principal: principalUser(userId: _memberUser),
        seasonId: 'not-a-uuid',
      );
      final error = (result as Err<SeasonLeaderboard>).error;
      expect(error.kind, ErrorKind.validation);
    });

    test('a withdrawn member may still read the board', () async {
      final h = _harness();
      h.competition.seedParticipant(
        boardParticipant(
          id: '00000000-0000-0000-0000-0000000000ab',
          seasonId: _season,
          userId: _memberUser,
          status: ParticipantStatus.withdrawn,
        ),
      );
      h.leaderboard.seed(_season, [
        boardEntry(participantId: _pA, totalPoints: 3),
      ]);
      final result = await h.useCase.call(
        principal: principalUser(userId: _memberUser),
        seasonId: _season,
      );
      expect(result, isA<Ok<SeasonLeaderboard>>());
    });
  });

  group('GetSeasonLeaderboard — projection + ranking', () {
    test('ranks the seeded standings (points desc, "1224" ties)', () async {
      final h = _harness();
      _enrolMember(h.competition);
      h.leaderboard.seed(_season, [
        boardEntry(
          participantId: _pA,
          totalPoints: 10,
          joinedAt: DateTime.utc(2026, 7, 1),
        ),
        boardEntry(
          participantId: _pB,
          totalPoints: 10,
          joinedAt: DateTime.utc(2026, 7, 2),
        ),
        boardEntry(participantId: _pC, totalPoints: 4),
      ]);
      final board =
          (await h.useCase.call(
                    principal: principalUser(userId: _memberUser),
                    seasonId: _season,
                  )
                  as Ok<SeasonLeaderboard>)
              .value;
      expect(board.seasonId.value, _season);
      expect(board.entries.map((e) => e.rank).toList(), [1, 1, 3]);
      expect(board.entries.map((e) => e.participantId.value).toList(), [
        _pA,
        _pB,
        _pC,
      ]);
    });

    test('an empty season yields an empty board (not an error)', () async {
      final h = _harness();
      _enrolMember(h.competition);
      h.leaderboard.seed(_season, const []);
      final board =
          (await h.useCase.call(
                    principal: principalUser(userId: _memberUser),
                    seasonId: _season,
                  )
                  as Ok<SeasonLeaderboard>)
              .value;
      expect(board.entries, isEmpty);
    });

    test('a zero-total participant appears, ranked last', () async {
      final h = _harness();
      _enrolMember(h.competition);
      h.leaderboard.seed(_season, [
        boardEntry(participantId: _pA, totalPoints: 0, entryCount: 0),
        boardEntry(participantId: _pB, totalPoints: 7),
      ]);
      final board =
          (await h.useCase.call(
                    principal: principalUser(userId: _memberUser),
                    seasonId: _season,
                  )
                  as Ok<SeasonLeaderboard>)
              .value;
      expect(board.entries.last.participantId.value, _pA);
      expect(board.entries.last.totalPoints, 0);
      expect(board.entries.last.rank, 2);
    });
  });

  group('GetSeasonLeaderboard — failure propagation', () {
    test('propagates a transient membership-lookup failure', () async {
      final h = _harness();
      h.competition.failNextWith(
        const AppError.transient('db.down', 'transient'),
      );
      final result = await h.useCase.call(
        principal: principalUser(userId: _memberUser),
        seasonId: _season,
      );
      expect(
        (result as Err<SeasonLeaderboard>).error.kind,
        ErrorKind.transient,
      );
    });

    test('propagates a transient standings-read failure', () async {
      final h = _harness();
      _enrolMember(h.competition);
      h.leaderboard.failNextWith(
        const AppError.transient('db.down', 'transient'),
      );
      final result = await h.useCase.call(
        principal: principalUser(userId: _memberUser),
        seasonId: _season,
      );
      expect(
        (result as Err<SeasonLeaderboard>).error.kind,
        ErrorKind.transient,
      );
    });
  });
}
