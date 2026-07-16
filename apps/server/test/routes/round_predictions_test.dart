import 'dart:io';

import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:server/composition/composition_root.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import 'competition_route_harness.dart';
// ignore: always_use_package_imports
import '../../routes/rounds/[id]/predictions/index.dart' as index;
// ignore: always_use_package_imports
import '../../routes/rounds/[id]/predictions/all.dart' as all;

/// Route tests for the Prediction surface, exercising the *real* wiring
/// (`context.read<Future<CompositionRoot>>()` → `root.<useCase>()`) over the
/// in-memory competition + prediction repositories, so the assertions cover the
/// edge → use-case → domain → port path end-to-end, hermetically.
void main() {
  const kParticipantId = '99999999-9999-9999-9999-999999999999';
  const kPredictionId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  const kOtherFixtureId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';

  final roundId = (RoundId.tryParse(kRoundId) as Ok<RoundId>).value;
  final seasonId = (SeasonId.tryParse(kSeasonId) as Ok<SeasonId>).value;
  final userId = (UserId.tryParse(kUserId) as Ok<UserId>).value;

  RulesetSnapshot snapshot() =>
      (RulesetSnapshot.create(payload: const {'exact': 3}, rulesetVersion: 1)
              as Ok<RulesetSnapshot>)
          .value;

  Round roundIn(RoundStatus status) => Round.fromStored(
    id: roundId,
    seasonId: seasonId,
    sequence: 1,
    predictionDeadline: DateTime.utc(2026, 8, 1, 12),
    status: status,
    ruleset: snapshot(),
  );

  Participant participant() => Participant.fromStored(
    id: (ParticipantId.tryParse(kParticipantId) as Ok<ParticipantId>).value,
    seasonId: seasonId,
    userId: userId,
    status: ParticipantStatus.active,
    joinedAt: DateTime.utc(2026, 7, 1),
  );

  RoundFixture link(String fixtureId, int order) => RoundFixture.fromStored(
    roundId: roundId,
    fixture: (FixtureRef.tryParse(fixtureId) as Ok<FixtureRef>).value,
    displayOrder: order,
  );

  /// Builds a composition root wiring all three prediction use-cases over the
  /// two in-memory repos, seeded for [status] with [fixtures] linked and the
  /// caller optionally a [joined] participant.
  ({CompositionRoot root, InMemoryPredictionRepository preds}) rootFor({
    required RoundStatus status,
    List<RoundFixture> fixtures = const [],
    bool joined = true,
  }) {
    final compRepo = InMemoryCompetitionRepository()
      ..rounds[kRoundId] = roundIn(status);
    if (joined) {
      compRepo.participants.add(participant());
    }
    final predRepo = InMemoryPredictionRepository()
      ..roundFixtures.addAll(fixtures);

    final root = CompositionRoot.forTesting(
      submitPrediction: SubmitPrediction(
        predictionRepository: predRepo,
        competitionRepository: compRepo,
        idGenerator: ScriptedIdGenerator([kPredictionId]),
        clock: FixedClock(DateTime.utc(2026, 7, 20, 9, 30)),
      ),
      getMyPrediction: GetMyPrediction(
        predictionRepository: predRepo,
        competitionRepository: compRepo,
      ),
      listRoundPredictions: ListRoundPredictions(
        predictionRepository: predRepo,
        competitionRepository: compRepo,
      ),
    );
    return (root: root, preds: predRepo);
  }

  group('POST /rounds/{id}/predictions', () {
    test(
      'submits a complete forecast for an open round and returns 200',
      () async {
        final setup = rootFor(
          status: RoundStatus.open,
          fixtures: [link(kFixtureId, 0)],
        );
        final context = wireContext(
          root: setup.root,
          principal: userPrincipal(),
          body: const {
            'fixture_scores': [
              {'fixture_id': kFixtureId, 'home_goals': 2, 'away_goals': 1},
            ],
          },
        );

        final response = await index.onRequest(context, kRoundId);

        expect(response.statusCode, HttpStatus.ok);
        final body = await decodeBody(response);
        expect(body['id'], kPredictionId);
        expect(body['round_id'], kRoundId);
        expect(body['participant_id'], kParticipantId);
        expect(body['submitted_at'], '2026-07-20T09:30:00.000Z');
        final scores = body['fixture_scores']! as List<Object?>;
        expect(scores, hasLength(1));
        final first = (scores.first! as Map).cast<String, Object?>();
        expect(first['fixture_id'], kFixtureId);
        expect(first['home_goals'], 2);
        expect(first['away_goals'], 1);
        // The read model never leaks points/score.
        expect(body.containsKey('points'), isFalse);
      },
    );

    test(
      'a second submission amends in place — still one prediction (200)',
      () async {
        final setup = rootFor(
          status: RoundStatus.open,
          fixtures: [link(kFixtureId, 0)],
        );
        Future<Response> submit(int home, int away) => index.onRequest(
          wireContext(
            root: setup.root,
            principal: userPrincipal(),
            body: {
              'fixture_scores': [
                {
                  'fixture_id': kFixtureId,
                  'home_goals': home,
                  'away_goals': away,
                },
              ],
            },
          ),
          kRoundId,
        );

        expect((await submit(1, 0)).statusCode, HttpStatus.ok);
        final response = await submit(3, 3);
        expect(response.statusCode, HttpStatus.ok);

        final listed = await setup.preds.listByRound(roundId);
        expect((listed as Ok<List<PredictionView>>).value, hasLength(1));
        final body = await decodeBody(response);
        final first = ((body['fixture_scores']! as List<Object?>).first! as Map)
            .cast<String, Object?>();
        expect(first['home_goals'], 3);
        expect(first['away_goals'], 3);
      },
    );

    test(
      'an incomplete forecast is rejected 400 incomplete_forecast',
      () async {
        final setup = rootFor(
          status: RoundStatus.open,
          fixtures: [link(kFixtureId, 0), link(kOtherFixtureId, 1)],
        );
        final response = await index.onRequest(
          wireContext(
            root: setup.root,
            principal: userPrincipal(),
            body: const {
              'fixture_scores': [
                {'fixture_id': kFixtureId, 'home_goals': 1, 'away_goals': 1},
              ],
            },
          ),
          kRoundId,
        );

        expect(response.statusCode, HttpStatus.badRequest);
        expect(
          (await decodeBody(response))['code'],
          'prediction.incomplete_forecast',
        );
      },
    );

    test(
      'submitting to a locked round is rejected 409 round_not_open',
      () async {
        final setup = rootFor(
          status: RoundStatus.locked,
          fixtures: [link(kFixtureId, 0)],
        );
        final response = await index.onRequest(
          wireContext(
            root: setup.root,
            principal: userPrincipal(),
            body: const {
              'fixture_scores': [
                {'fixture_id': kFixtureId, 'home_goals': 0, 'away_goals': 0},
              ],
            },
          ),
          kRoundId,
        );

        expect(response.statusCode, HttpStatus.conflict);
        expect(
          (await decodeBody(response))['code'],
          'prediction.round_not_open',
        );
      },
    );

    test('a non-participant is rejected 409 not_a_participant', () async {
      final setup = rootFor(
        status: RoundStatus.open,
        fixtures: [link(kFixtureId, 0)],
        joined: false,
      );
      final response = await index.onRequest(
        wireContext(
          root: setup.root,
          principal: userPrincipal(),
          body: const {
            'fixture_scores': [
              {'fixture_id': kFixtureId, 'home_goals': 1, 'away_goals': 0},
            ],
          },
        ),
        kRoundId,
      );

      expect(response.statusCode, HttpStatus.conflict);
      expect(
        (await decodeBody(response))['code'],
        'prediction.not_a_participant',
      );
    });

    test('a missing fixture_scores field is 400', () async {
      final setup = rootFor(
        status: RoundStatus.open,
        fixtures: [link(kFixtureId, 0)],
      );
      final response = await index.onRequest(
        wireContext(
          root: setup.root,
          principal: userPrincipal(),
          body: const {'schema_version': 1},
        ),
        kRoundId,
      );

      expect(response.statusCode, HttpStatus.badRequest);
      expect((await decodeBody(response))['code'], 'request.field_missing');
    });

    test('a non-GET/POST method is 405', () async {
      final setup = rootFor(status: RoundStatus.open);
      final response = await index.onRequest(
        wireContext(
          root: setup.root,
          principal: userPrincipal(),
          method: HttpMethod.delete,
        ),
        kRoundId,
      );
      expect(response.statusCode, HttpStatus.methodNotAllowed);
    });
  });

  group('GET /rounds/{id}/predictions (my prediction)', () {
    test(
      'returns 404 prediction.not_found when nothing submitted yet',
      () async {
        final setup = rootFor(
          status: RoundStatus.open,
          fixtures: [link(kFixtureId, 0)],
        );
        final response = await index.onRequest(
          wireContext(
            root: setup.root,
            principal: userPrincipal(),
            method: HttpMethod.get,
          ),
          kRoundId,
        );

        expect(response.statusCode, HttpStatus.notFound);
        expect((await decodeBody(response))['code'], 'prediction.not_found');
      },
    );

    test(
      'returns 200 with the caller own prediction after submitting',
      () async {
        final setup = rootFor(
          status: RoundStatus.open,
          fixtures: [link(kFixtureId, 0)],
        );
        await index.onRequest(
          wireContext(
            root: setup.root,
            principal: userPrincipal(),
            body: const {
              'fixture_scores': [
                {'fixture_id': kFixtureId, 'home_goals': 4, 'away_goals': 2},
              ],
            },
          ),
          kRoundId,
        );

        final response = await index.onRequest(
          wireContext(
            root: setup.root,
            principal: userPrincipal(),
            method: HttpMethod.get,
          ),
          kRoundId,
        );

        expect(response.statusCode, HttpStatus.ok);
        final body = await decodeBody(response);
        expect(body['id'], kPredictionId);
        final first = ((body['fixture_scores']! as List<Object?>).first! as Map)
            .cast<String, Object?>();
        expect(first['home_goals'], 4);
      },
    );
  });

  group('GET /rounds/{id}/predictions/all', () {
    test('an open round is gated 401 round_not_locked', () async {
      final setup = rootFor(
        status: RoundStatus.open,
        fixtures: [link(kFixtureId, 0)],
      );
      final response = await all.onRequest(
        wireContext(
          root: setup.root,
          principal: userPrincipal(),
          method: HttpMethod.get,
        ),
        kRoundId,
      );

      expect(response.statusCode, HttpStatus.unauthorized);
      expect(
        (await decodeBody(response))['code'],
        'prediction.round_not_locked',
      );
    });

    test(
      'a locked round returns the (possibly empty) list to a participant',
      () async {
        // Submit while open, then serve the list after the round is locked. Both
        // phases share one prediction repo; only the round status changes.
        final predRepo = InMemoryPredictionRepository()
          ..roundFixtures.add(link(kFixtureId, 0));
        final compRepo = InMemoryCompetitionRepository()
          ..participants.add(participant())
          ..rounds[kRoundId] = roundIn(RoundStatus.open);

        final openRoot = CompositionRoot.forTesting(
          submitPrediction: SubmitPrediction(
            predictionRepository: predRepo,
            competitionRepository: compRepo,
            idGenerator: ScriptedIdGenerator([kPredictionId]),
            clock: FixedClock(DateTime.utc(2026, 7, 20, 9, 30)),
          ),
        );
        await index.onRequest(
          wireContext(
            root: openRoot,
            principal: userPrincipal(),
            body: const {
              'fixture_scores': [
                {'fixture_id': kFixtureId, 'home_goals': 2, 'away_goals': 2},
              ],
            },
          ),
          kRoundId,
        );

        // Lock the round, then list.
        compRepo.rounds[kRoundId] = roundIn(RoundStatus.locked);
        final lockedRoot = CompositionRoot.forTesting(
          listRoundPredictions: ListRoundPredictions(
            predictionRepository: predRepo,
            competitionRepository: compRepo,
          ),
        );
        final response = await all.onRequest(
          wireContext(
            root: lockedRoot,
            principal: userPrincipal(),
            method: HttpMethod.get,
          ),
          kRoundId,
        );

        expect(response.statusCode, HttpStatus.ok);
        final decoded = await response.json() as List<Object?>;
        expect(decoded, hasLength(1));
        final only = (decoded.first! as Map).cast<String, Object?>();
        expect(only['participant_id'], kParticipantId);
      },
    );

    test(
      'a non-participant is rejected 401 not_a_participant on a locked round',
      () async {
        final setup = rootFor(
          status: RoundStatus.locked,
          fixtures: [link(kFixtureId, 0)],
          joined: false,
        );
        final response = await all.onRequest(
          wireContext(
            root: setup.root,
            principal: userPrincipal(),
            method: HttpMethod.get,
          ),
          kRoundId,
        );

        expect(response.statusCode, HttpStatus.unauthorized);
        expect(
          (await decodeBody(response))['code'],
          'prediction.not_a_participant',
        );
      },
    );
  });
}
