import 'dart:io';

import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:server/composition/composition_root.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import 'competition_route_harness.dart';
// ignore: always_use_package_imports
import '../../routes/fixtures/[id]/result/index.dart' as result_route;
// ignore: always_use_package_imports
import '../../routes/rounds/[id]/score/index.dart' as score_route;
// ignore: always_use_package_imports
import '../../routes/rounds/[id]/scores/index.dart' as scores_route;

/// Route tests for the Scoring surface — the three routes
/// `PUT /fixtures/{id}/result`, `POST /rounds/{id}/score`, and
/// `GET /rounds/{id}/scores`.
///
/// They exercise the *real* wiring (`context.read<Future<CompositionRoot>>()`
/// → `root.<useCase>()`) over the in-memory competition + prediction + scoring
/// repositories from [competition_route_harness], so the assertions cover the
/// edge → use-case → domain → port path end-to-end, hermetically. This mirrors
/// `round_predictions_test.dart` + `season_rounds_test.dart`. It is NOT a
/// substitute for the infrastructure adapters' own tests (those live in the
/// infrastructure package) or the use-cases' own tests (application package):
/// its job is the route's status mapping, DTO shaping, admin gating, and the
/// visibility gates surfaced across the HTTP boundary.
void main() {
  // A second fixture and participant beyond the harness canon, so multi-fixture
  // / multi-participant paths are covered.
  const kFixtureId2 = 'cccccccc-cccc-cccc-cccc-cccccccccccc';
  const kParticipantId = '99999999-9999-9999-9999-999999999999';
  const kOtherParticipantId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  const kPredictionId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';

  final roundId = (RoundId.tryParse(kRoundId) as Ok<RoundId>).value;

  /// The exact `football_scoreline` payload the production
  /// `ConfiguredRulesetProvider` freezes at open time — the one
  /// [ScoringRuleset.fromSnapshot] parses. exact=3 / outcome=1 / incorrect=0.
  RulesetSnapshot snapshot() =>
      (RulesetSnapshot.create(
                payload: const {
                  'format': 'football_scoreline',
                  'points': {
                    'exact_scoreline': 3,
                    'correct_outcome': 1,
                    'incorrect': 0,
                  },
                },
                rulesetVersion: 1,
              )
              as Ok<RulesetSnapshot>)
          .value;

  Round roundIn(RoundStatus status) => Round.fromStored(
    id: roundId,
    seasonId: (SeasonId.tryParse(kSeasonId) as Ok<SeasonId>).value,
    sequence: 1,
    predictionDeadline: DateTime.utc(2026, 8, 1, 12),
    status: status,
    ruleset: snapshot(),
  );

  Participant participant(String id, String userId) => Participant.fromStored(
    id: (ParticipantId.tryParse(id) as Ok<ParticipantId>).value,
    seasonId: (SeasonId.tryParse(kSeasonId) as Ok<SeasonId>).value,
    userId: (UserId.tryParse(userId) as Ok<UserId>).value,
    status: ParticipantStatus.active,
    joinedAt: DateTime.utc(2026, 7, 1),
  );

  RoundFixture link(String fixtureId, int order) => RoundFixture.fromStored(
    roundId: roundId,
    fixture: (FixtureRef.tryParse(fixtureId) as Ok<FixtureRef>).value,
    displayOrder: order,
  );

  FixtureResult actualResult(String fixtureId, int home, int away) =>
      FixtureResult.fromStored(
        fixture: (FixtureRef.tryParse(fixtureId) as Ok<FixtureRef>).value,
        homeGoals: home,
        awayGoals: away,
      );

  Prediction prediction({
    required String id,
    required String participantId,
    required List<(String fixtureId, int home, int away)> scores,
  }) => Prediction.fromStored(
    id: (PredictionId.tryParse(id) as Ok<PredictionId>).value,
    roundId: roundId,
    participantId:
        (ParticipantId.tryParse(participantId) as Ok<ParticipantId>).value,
    scores: [
      for (final (fixtureId, home, away) in scores)
        (FixtureScorePrediction.create(
                  fixture:
                      (FixtureRef.tryParse(fixtureId) as Ok<FixtureRef>).value,
                  homeGoals: home,
                  awayGoals: away,
                )
                as Ok<FixtureScorePrediction>)
            .value,
    ],
  );

  // ---------------------------------------------------------------------------
  // PUT /fixtures/{id}/result — RecordFixtureResult (admin-only ingestion)
  // ---------------------------------------------------------------------------
  group('PUT /fixtures/{id}/result', () {
    ({CompositionRoot root, InMemoryFixtureResultRepository results})
    rootFor() {
      final results = InMemoryFixtureResultRepository();
      final root = CompositionRoot.forTesting(
        recordFixtureResult: RecordFixtureResult(
          resultRepository: results,
          clock: FixedClock(_at),
        ),
      );
      return (root: root, results: results);
    }

    test(
      'an admin records a result and gets 200 with the stored scoreline',
      () async {
        final setup = rootFor();
        final response = await result_route.onRequest(
          wireContext(
            root: setup.root,
            principal: adminPrincipal(),
            method: HttpMethod.put,
            body: const {'home_goals': 2, 'away_goals': 1},
          ),
          kFixtureId,
        );

        expect(response.statusCode, HttpStatus.ok);
        final body = await decodeBody(response);
        expect(body['fixture_id'], kFixtureId);
        expect(body['home_goals'], 2);
        expect(body['away_goals'], 1);
        // The result surface is the actual scoreline, never a score.
        expect(body.containsKey('points'), isFalse);
        // The scoreline was actually persisted behind the seam.
        final stored = await setup.results.findByFixture(
          (FixtureRef.tryParse(kFixtureId) as Ok<FixtureRef>).value,
        );
        final value = (stored as Ok<FixtureResult?>).value!;
        expect(value.homeGoals, 2);
        expect(value.awayGoals, 1);
        // The clock-stamped recorded-at instant is the ingestion audit.
        expect(setup.results.recordedAt[kFixtureId], _at);
      },
    );

    test('a non-admin caller is rejected 401 (admin-only gate)', () async {
      final setup = rootFor();
      final response = await result_route.onRequest(
        wireContext(
          root: setup.root,
          principal: userPrincipal(),
          method: HttpMethod.put,
          body: const {'home_goals': 1, 'away_goals': 0},
        ),
        kFixtureId,
      );

      expect(response.statusCode, HttpStatus.unauthorized);
      expect((await decodeBody(response))['code'], 'auth.insufficient_role');
      // Nothing was written on the rejected path.
      expect(setup.results.count, 0);
    });

    test(
      'recording the same fixture twice is idempotent — one stored row',
      () async {
        final setup = rootFor();
        Future<Response> record(int home, int away) => result_route.onRequest(
          wireContext(
            root: setup.root,
            principal: adminPrincipal(),
            method: HttpMethod.put,
            body: {'home_goals': home, 'away_goals': away},
          ),
          kFixtureId,
        );

        expect((await record(0, 0)).statusCode, HttpStatus.ok);
        // Correct a mistyped scoreline before scoring: upsert in place.
        final second = await record(3, 2);
        expect(second.statusCode, HttpStatus.ok);
        expect(setup.results.count, 1);
        final body = await decodeBody(second);
        expect(body['home_goals'], 3);
        expect(body['away_goals'], 2);
      },
    );

    test('a negative scoreline is rejected 400 (domain validation)', () async {
      final setup = rootFor();
      final response = await result_route.onRequest(
        wireContext(
          root: setup.root,
          principal: adminPrincipal(),
          method: HttpMethod.put,
          body: const {'home_goals': -1, 'away_goals': 0},
        ),
        kFixtureId,
      );

      expect(response.statusCode, HttpStatus.badRequest);
      expect(setup.results.count, 0);
    });

    test('a missing goal field is 400 (transport validation)', () async {
      final setup = rootFor();
      final response = await result_route.onRequest(
        wireContext(
          root: setup.root,
          principal: adminPrincipal(),
          method: HttpMethod.put,
          body: const {'home_goals': 1},
        ),
        kFixtureId,
      );

      expect(response.statusCode, HttpStatus.badRequest);
      expect((await decodeBody(response))['code'], 'request.field_missing');
      expect(setup.results.count, 0);
    });

    test('a non-PUT method is 405', () async {
      final setup = rootFor();
      final response = await result_route.onRequest(
        wireContext(
          root: setup.root,
          principal: adminPrincipal(),
          body: const {'home_goals': 1, 'away_goals': 0},
        ),
        kFixtureId,
      );
      expect(response.statusCode, HttpStatus.methodNotAllowed);
    });
  });

  // ---------------------------------------------------------------------------
  // POST /rounds/{id}/score — ScoreRound (admin-only command)
  // ---------------------------------------------------------------------------
  group('POST /rounds/{id}/score', () {
    /// Wires all three scoring collaborators over the round in [status], the
    /// two linked fixtures, the [predictions] seeded, and the actual [results]
    /// (defaulting to a complete set: f1 = 2-1 home win, f2 = 0-0 draw).
    Future<
      ({
        CompositionRoot root,
        InMemoryCompetitionRepository comp,
        InMemoryScoreRepository scores,
      })
    >
    rootFor({
      required RoundStatus status,
      List<Prediction> predictions = const [],
      bool completeResults = true,
    }) async {
      final comp = InMemoryCompetitionRepository()
        ..rounds[kRoundId] = roundIn(status);
      final preds = InMemoryPredictionRepository()
        ..roundFixtures.addAll([link(kFixtureId, 0), link(kFixtureId2, 1)]);
      for (final p in predictions) {
        // Seed a stored prediction directly via save (the repo stamps it).
        await preds.save(p, _at);
      }
      final results = InMemoryFixtureResultRepository();
      await results.upsert(actualResult(kFixtureId, 2, 1), _at);
      if (completeResults) {
        await results.upsert(actualResult(kFixtureId2, 0, 0), _at);
      }
      final scores = InMemoryScoreRepository();

      final root = CompositionRoot.forTesting(
        scoreRound: ScoreRound(
          competitionRepository: comp,
          predictionRepository: preds,
          resultRepository: results,
          scoreRepository: scores,
        ),
      );
      return (root: root, comp: comp, scores: scores);
    }

    Future<Response> post(CompositionRoot root, AuthenticatedUser principal) =>
        score_route.onRequest(
          wireContext(
            root: root,
            principal: principal,
            method: HttpMethod.post,
          ),
          kRoundId,
        );

    test(
      'an admin scores a locked round and gets 200 with the round scores',
      () async {
        final setup = await rootFor(
          status: RoundStatus.locked,
          predictions: [
            // p1: f1 exact (2-1) → 3, f2 outcome (1-1 draw) → 1 = 4.
            prediction(
              id: kPredictionId,
              participantId: kParticipantId,
              scores: [(kFixtureId, 2, 1), (kFixtureId2, 1, 1)],
            ),
          ],
        );

        final response = await post(setup.root, adminPrincipal());

        expect(response.statusCode, HttpStatus.ok);
        final body = await decodeBody(response);
        expect(body['round_id'], kRoundId);
        final scores = body['scores']! as List<Object?>;
        expect(scores, hasLength(1));
        final only = (scores.first! as Map).cast<String, Object?>();
        expect(only['participant_id'], kParticipantId);
        expect(only['ruleset_version'], 1);
        expect(only['total_points'], 4);
        final breakdown = only['fixture_results']! as List<Object?>;
        expect(breakdown, hasLength(2));
        final first = (breakdown.first! as Map).cast<String, Object?>();
        expect(first['fixture_id'], kFixtureId);
        expect(first['grade'], 'exact_scoreline');
        expect(first['points'], 3);
        final second = (breakdown[1]! as Map).cast<String, Object?>();
        expect(second['grade'], 'correct_outcome');
        expect(second['points'], 1);
        // The round transitioned locked → scored.
        expect(setup.comp.rounds[kRoundId]!.status, RoundStatus.scored);
        expect(setup.scores.count, 1);
      },
    );

    test('a non-admin caller is rejected 401 (admin-only gate)', () async {
      final setup = await rootFor(status: RoundStatus.locked);
      final response = await post(setup.root, userPrincipal());

      expect(response.statusCode, HttpStatus.unauthorized);
      expect((await decodeBody(response))['code'], 'auth.insufficient_role');
      // Nothing was scored and the round stays locked.
      expect(setup.scores.count, 0);
      expect(setup.comp.rounds[kRoundId]!.status, RoundStatus.locked);
    });

    test(
      'scoring an open round is rejected 409 scoring.round_not_locked',
      () async {
        final setup = await rootFor(status: RoundStatus.open);
        final response = await post(setup.root, adminPrincipal());

        expect(response.statusCode, HttpStatus.conflict);
        expect(
          (await decodeBody(response))['code'],
          'scoring.round_not_locked',
        );
        expect(setup.scores.count, 0);
        expect(setup.comp.rounds[kRoundId]!.status, RoundStatus.open);
      },
    );

    test('scoring with an incomplete result set is rejected 409 '
        'scoring.results_incomplete', () async {
      final setup = await rootFor(
        status: RoundStatus.locked,
        completeResults: false,
        predictions: [
          prediction(
            id: kPredictionId,
            participantId: kParticipantId,
            scores: [(kFixtureId, 2, 1), (kFixtureId2, 0, 0)],
          ),
        ],
      );
      final response = await post(setup.root, adminPrincipal());

      expect(response.statusCode, HttpStatus.conflict);
      expect(
        (await decodeBody(response))['code'],
        'scoring.results_incomplete',
      );
      expect(setup.scores.count, 0);
      // The round is untouched — still locked, ready to be scored once complete.
      expect(setup.comp.rounds[kRoundId]!.status, RoundStatus.locked);
    });

    test('re-scoring an already-scored round is idempotent (200, one row, '
        'no transition conflict)', () async {
      final setup = await rootFor(
        status: RoundStatus.locked,
        predictions: [
          prediction(
            id: kPredictionId,
            participantId: kParticipantId,
            scores: [(kFixtureId, 2, 1), (kFixtureId2, 0, 0)],
          ),
        ],
      );

      // First score: locked → scored.
      final first = await post(setup.root, adminPrincipal());
      expect(first.statusCode, HttpStatus.ok);
      expect(setup.comp.rounds[kRoundId]!.status, RoundStatus.scored);
      expect(setup.scores.count, 1);
      final firstTotal =
          ((await decodeBody(first))['scores']! as List<Object?>).length;

      // Second score on the now-scored round: recomputes the identical result,
      // re-persists it, reports 200, still one row, no spurious conflict.
      final second = await post(setup.root, adminPrincipal());
      expect(second.statusCode, HttpStatus.ok);
      expect(setup.scores.count, 1);
      final secondScores =
          (await decodeBody(second))['scores']! as List<Object?>;
      expect(secondScores, hasLength(firstTotal));
      final only = (secondScores.first! as Map).cast<String, Object?>();
      // p1: f1 exact (3) + f2 exact (3) = 6.
      expect(only['total_points'], 6);
    });

    test('a non-POST method is 405', () async {
      final setup = await rootFor(status: RoundStatus.locked);
      final response = await score_route.onRequest(
        wireContext(
          root: setup.root,
          principal: adminPrincipal(),
          method: HttpMethod.get,
        ),
        kRoundId,
      );
      expect(response.statusCode, HttpStatus.methodNotAllowed);
    });
  });

  // ---------------------------------------------------------------------------
  // GET /rounds/{id}/scores — GetRoundScores (participant read, scored-gated)
  // ---------------------------------------------------------------------------
  group('GET /rounds/{id}/scores', () {
    /// Wires the read use-case over a competition repo carrying the round in
    /// [status], the caller optionally [joined] as a participant, and a score
    /// repo pre-seeded with [seededScores].
    Future<({CompositionRoot root, InMemoryScoreRepository scores})> rootFor({
      required RoundStatus status,
      bool joined = true,
      List<RoundScore> seededScores = const [],
    }) async {
      final comp = InMemoryCompetitionRepository()
        ..rounds[kRoundId] = roundIn(status);
      if (joined) {
        comp.participants.add(participant(kParticipantId, kUserId));
      }
      final scores = InMemoryScoreRepository();
      if (seededScores.isNotEmpty) {
        await scores.saveRoundScores(seededScores);
      }
      final root = CompositionRoot.forTesting(
        getRoundScores: GetRoundScores(
          competitionRepository: comp,
          scoreRepository: scores,
        ),
      );
      return (root: root, scores: scores);
    }

    /// A stored score for [participantId], grading its single fixture exact (3).
    RoundScore storedScore(String participantId) => RoundScore.fromStored(
      roundId: roundId,
      participantId:
          (ParticipantId.tryParse(participantId) as Ok<ParticipantId>).value,
      rulesetVersion: 1,
      totalPoints: 3,
      fixtureResults: [
        FixtureScoreResult(
          fixture: (FixtureRef.tryParse(kFixtureId) as Ok<FixtureRef>).value,
          grade: FixtureScoreGrade.exactScoreline,
          points: 3,
        ),
      ],
    );

    Future<Response> get(CompositionRoot root, AuthenticatedUser principal) =>
        scores_route.onRequest(
          wireContext(root: root, principal: principal, method: HttpMethod.get),
          kRoundId,
        );

    test('a participant reads the scored round scores and gets 200', () async {
      final setup = await rootFor(
        status: RoundStatus.scored,
        seededScores: [
          storedScore(kParticipantId),
          storedScore(kOtherParticipantId),
        ],
      );

      final response = await get(setup.root, userPrincipal());

      expect(response.statusCode, HttpStatus.ok);
      final body = await decodeBody(response);
      expect(body['round_id'], kRoundId);
      final scores = body['scores']! as List<Object?>;
      expect(scores, hasLength(2));
      // Participant-id ordered: kOtherParticipantId ('aaaa…') sorts before
      // kParticipantId ('9999…')? No — '9' (0x39) < 'a' (0x61), so kParticipant
      // is first. Assert the ordering the repo guarantees.
      final firstId = (scores.first! as Map)
          .cast<String, Object?>()['participant_id'];
      final secondId = (scores[1]! as Map)
          .cast<String, Object?>()['participant_id'];
      expect([firstId, secondId], [kParticipantId, kOtherParticipantId]);
      final first = (scores.first! as Map).cast<String, Object?>();
      expect(first['total_points'], 3);
      expect(first['ruleset_version'], 1);
    });

    test(
      'reading a scored round with no predictions returns 200 + empty list',
      () async {
        final setup = await rootFor(status: RoundStatus.scored);
        final response = await get(setup.root, userPrincipal());

        expect(response.statusCode, HttpStatus.ok);
        final body = await decodeBody(response);
        // Scored-but-empty is distinct from the 409 "too early" case.
        expect(body['scores'], isEmpty);
      },
    );

    test(
      'reading before scoring is rejected 409 scoring.round_not_scored',
      () async {
        final setup = await rootFor(status: RoundStatus.locked);
        final response = await get(setup.root, userPrincipal());

        expect(response.statusCode, HttpStatus.conflict);
        expect(
          (await decodeBody(response))['code'],
          'scoring.round_not_scored',
        );
      },
    );

    test(
      'a non-participant is rejected 401 scoring.not_a_participant',
      () async {
        final setup = await rootFor(
          status: RoundStatus.scored,
          joined: false,
          seededScores: [storedScore(kParticipantId)],
        );
        final response = await get(setup.root, userPrincipal());

        expect(response.statusCode, HttpStatus.unauthorized);
        expect(
          (await decodeBody(response))['code'],
          'scoring.not_a_participant',
        );
      },
    );

    test('a non-GET method is 405', () async {
      final setup = await rootFor(status: RoundStatus.scored);
      final response = await scores_route.onRequest(
        wireContext(
          root: setup.root,
          principal: userPrincipal(),
          method: HttpMethod.post,
        ),
        kRoundId,
      );
      expect(response.statusCode, HttpStatus.methodNotAllowed);
    });
  });
}

/// A fixed UTC instant used for every clock-stamped write in these tests, so
/// recorded-at audits are deterministic.
final DateTime _at = DateTime.utc(2026, 7, 20, 9, 30);
