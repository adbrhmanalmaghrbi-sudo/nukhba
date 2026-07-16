import 'dart:io';

import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:server/composition/composition_root.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import 'competition_route_harness.dart';
// ignore: always_use_package_imports
import '../../routes/seasons/[id]/leaderboard/index.dart' as leaderboard_route;

/// Route test for the Leaderboards surface — `GET /seasons/{id}/leaderboard`.
///
/// It exercises the *real* wiring (`context.read<Future<CompositionRoot>>()` →
/// `root.getSeasonLeaderboard()`) over the in-memory competition + leaderboard
/// repositories from [competition_route_harness], so the assertions cover the
/// edge → use-case → domain → port path end-to-end, hermetically. It mirrors
/// `scoring_routes_test.dart` + `season_rounds_test.dart`. It is NOT a
/// substitute for the infrastructure adapter's own tests (infrastructure
/// package) or the use-case's own tests (application package): its job is the
/// route's status mapping, DTO shaping, the ranked ordering across the HTTP
/// boundary, and the season-membership visibility gate.
void main() {
  const kParticipantSelf = '99999999-9999-9999-9999-999999999999';
  const kParticipantOther = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  const kParticipantThird = 'cccccccc-cccc-cccc-cccc-cccccccccccc';

  final seasonId = (SeasonId.tryParse(kSeasonId) as Ok<SeasonId>).value;

  /// A participant of the harness season, owned by [userId].
  Participant participant(String id, String userId) => Participant.fromStored(
    id: (ParticipantId.tryParse(id) as Ok<ParticipantId>).value,
    seasonId: seasonId,
    userId: (UserId.tryParse(userId) as Ok<UserId>).value,
    status: ParticipantStatus.active,
    joinedAt: DateTime.utc(2026, 7, 1),
  );

  /// An unranked projection entry (as the VIEW adapter produces).
  LeaderboardEntry entry(
    String participantId,
    int total,
    int count,
    DateTime joinedAt,
  ) =>
      (LeaderboardEntry.projected(
                participantId:
                    (ParticipantId.tryParse(participantId) as Ok<ParticipantId>)
                        .value,
                totalPoints: total,
                entryCount: count,
                joinedAt: joinedAt,
              )
              as Ok<LeaderboardEntry>)
          .value;

  ({
    CompositionRoot root,
    InMemoryCompetitionRepository competition,
    InMemoryLeaderboardRepository leaderboard,
  })
  rootFor() {
    final competition = InMemoryCompetitionRepository();
    final leaderboard = InMemoryLeaderboardRepository();
    final root = CompositionRoot.forTesting(
      getSeasonLeaderboard: GetSeasonLeaderboard(
        leaderboardRepository: leaderboard,
        competitionRepository: competition,
      ),
    );
    return (root: root, competition: competition, leaderboard: leaderboard);
  }

  group('GET /seasons/{id}/leaderboard', () {
    test(
      'a member reads the ranked board (200), points-desc then joinedAt-asc',
      () async {
        final setup = rootFor();
        // The caller is a member of the season (userPrincipal → kUserId).
        await setup.competition.saveParticipant(
          participant(kParticipantSelf, kUserId),
        );
        // Seed three unranked projections in deliberately non-sorted input order.
        setup.leaderboard.seed(kSeasonId, [
          entry(kParticipantOther, 5, 2, DateTime.utc(2026, 7, 2)),
          entry(kParticipantSelf, 9, 3, DateTime.utc(2026, 7, 1)),
          entry(kParticipantThird, 5, 1, DateTime.utc(2026, 7, 1)),
        ]);

        final response = await leaderboard_route.onRequest(
          wireContext(
            root: setup.root,
            principal: userPrincipal(),
            method: HttpMethod.get,
          ),
          kSeasonId,
        );

        expect(response.statusCode, HttpStatus.ok);
        final body = await decodeBody(response);
        expect(body['season_id'], kSeasonId);
        final entries = (body['entries']! as List)
            .cast<Map<Object?, Object?>>();
        expect(entries.length, 3);

        // Rank 1: highest total (9).
        expect(entries[0]['participant_id'], kParticipantSelf);
        expect(entries[0]['rank'], 1);
        expect(entries[0]['total_points'], 9);
        expect(entries[0]['entry_count'], 3);

        // Tie on 5: standard "1224" — both share rank 2; the earlier joiner
        // (kParticipantThird joined 07-01) displays before kParticipantOther
        // (joined 07-02).
        expect(entries[1]['participant_id'], kParticipantThird);
        expect(entries[1]['rank'], 2);
        expect(entries[2]['participant_id'], kParticipantOther);
        expect(entries[2]['rank'], 2);

        // No group reference leaks onto an entry (Axiom 4).
        expect(entries[0].containsKey('group_id'), isFalse);
      },
    );

    test(
      'an enrolled-but-never-credited member appears with a zero row',
      () async {
        final setup = rootFor();
        await setup.competition.saveParticipant(
          participant(kParticipantSelf, kUserId),
        );
        setup.leaderboard.seed(kSeasonId, [
          entry(kParticipantOther, 4, 1, DateTime.utc(2026, 7, 1)),
          entry(kParticipantSelf, 0, 0, DateTime.utc(2026, 7, 3)),
        ]);

        final response = await leaderboard_route.onRequest(
          wireContext(
            root: setup.root,
            principal: userPrincipal(),
            method: HttpMethod.get,
          ),
          kSeasonId,
        );

        expect(response.statusCode, HttpStatus.ok);
        final entries = ((await decodeBody(response))['entries']! as List)
            .cast<Map<Object?, Object?>>();
        // Zero-total member ranks last but is present with 0/0.
        expect(entries.last['participant_id'], kParticipantSelf);
        expect(entries.last['total_points'], 0);
        expect(entries.last['entry_count'], 0);
        expect(entries.last['rank'], 2);
      },
    );

    test('a season with no participants is a 200 empty board', () async {
      final setup = rootFor();
      // The caller must still be a member to see the (empty) board.
      await setup.competition.saveParticipant(
        participant(kParticipantSelf, kUserId),
      );
      // No seeded standings → the adapter returns an empty projection.

      final response = await leaderboard_route.onRequest(
        wireContext(
          root: setup.root,
          principal: userPrincipal(),
          method: HttpMethod.get,
        ),
        kSeasonId,
      );

      expect(response.statusCode, HttpStatus.ok);
      final body = await decodeBody(response);
      expect(body['season_id'], kSeasonId);
      expect((body['entries']! as List), isEmpty);
    });

    test('a non-member is refused 401 leaderboard.not_a_participant', () async {
      final setup = rootFor();
      // The caller (kUserId) has NOT joined the season; seeding standings for
      // OTHER participants must not leak to them.
      setup.leaderboard.seed(kSeasonId, [
        entry(kParticipantOther, 7, 2, DateTime.utc(2026, 7, 1)),
      ]);

      final response = await leaderboard_route.onRequest(
        wireContext(
          root: setup.root,
          principal: userPrincipal(),
          method: HttpMethod.get,
        ),
        kSeasonId,
      );

      expect(response.statusCode, HttpStatus.unauthorized);
      expect(
        (await decodeBody(response))['code'],
        'leaderboard.not_a_participant',
      );
    });

    test('a malformed season id is 400 (validation)', () async {
      final setup = rootFor();
      final response = await leaderboard_route.onRequest(
        wireContext(
          root: setup.root,
          principal: userPrincipal(),
          method: HttpMethod.get,
        ),
        'not-a-uuid',
      );

      expect(response.statusCode, HttpStatus.badRequest);
    });

    test('a non-GET method is 405', () async {
      final setup = rootFor();
      final response = await leaderboard_route.onRequest(
        wireContext(
          root: setup.root,
          principal: userPrincipal(),
          method: HttpMethod.post,
        ),
        kSeasonId,
      );

      expect(response.statusCode, HttpStatus.methodNotAllowed);
    });
  });
}
