import 'dart:io';

import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:server/composition/composition_root.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import 'competition_route_harness.dart';
// ignore: always_use_package_imports
import '../../routes/participants/[id]/balance/index.dart' as balance_route;
// ignore: always_use_package_imports
import '../../routes/participants/[id]/entries/index.dart' as entries_route;
// ignore: always_use_package_imports
import '../../routes/rounds/[id]/ledger/index.dart' as post_ledger_route;

/// Route tests for the Ledger surface — the three routes
/// `POST /rounds/{id}/ledger` (post a scored round to the append-only ledger),
/// `GET /participants/{id}/balance`, and `GET /participants/{id}/entries`.
///
/// They exercise the *real* wiring (`context.read<Future<CompositionRoot>>()`
/// → `root.<useCase>()`) over the in-memory competition + scoring + ledger
/// repositories from [competition_route_harness], so the assertions cover the
/// edge → use-case → domain → port path end-to-end, hermetically. This mirrors
/// `scoring_routes_test.dart`. It is NOT a substitute for the infrastructure
/// adapters' own tests (infrastructure package) or the use-cases' own tests
/// (application package): its job is the route's status mapping, DTO shaping,
/// admin gating (post), the self-read ownership gate (reads), and idempotency
/// surfaced across the HTTP boundary.
void main() {
  const kParticipantId = '99999999-9999-9999-9999-999999999999';
  const kOtherParticipantId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  // The user who owns kOtherParticipantId (distinct from the harness kUserId,
  // which owns kParticipantId), so a foreign-participant read can be exercised.
  const kOtherUserId = 'dddddddd-dddd-dddd-dddd-dddddddddddd';
  // Scripted point-entry ids the PostRoundToLedger use-case draws for the
  // credits it builds (one per scored participant).
  const kEntryId1 = 'e1111111-1111-1111-1111-111111111111';
  const kEntryId2 = 'e2222222-2222-2222-2222-222222222222';
  const kFixtureId = '66666666-6666-6666-6666-666666666666';

  final roundId = (RoundId.tryParse(kRoundId) as Ok<RoundId>).value;

  Round roundIn(RoundStatus status) => Round.fromStored(
    id: roundId,
    seasonId: (SeasonId.tryParse(kSeasonId) as Ok<SeasonId>).value,
    sequence: 1,
    predictionDeadline: DateTime.utc(2026, 8, 1, 12),
    status: status,
    ruleset:
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
            .value,
  );

  Participant participant(String id, String userId) => Participant.fromStored(
    id: (ParticipantId.tryParse(id) as Ok<ParticipantId>).value,
    seasonId: (SeasonId.tryParse(kSeasonId) as Ok<SeasonId>).value,
    userId: (UserId.tryParse(userId) as Ok<UserId>).value,
    status: ParticipantStatus.active,
    joinedAt: DateTime.utc(2026, 7, 1),
  );

  /// A stored score for [participantId] totalling [total] points over a single
  /// exact-scoreline fixture (the fixture breakdown is irrelevant to the ledger
  /// — the ledger consumes only totalPoints).
  RoundScore storedScore(String participantId, int total) =>
      RoundScore.fromStored(
        roundId: roundId,
        participantId:
            (ParticipantId.tryParse(participantId) as Ok<ParticipantId>).value,
        rulesetVersion: 1,
        totalPoints: total,
        fixtureResults: [
          FixtureScoreResult(
            fixture: (FixtureRef.tryParse(kFixtureId) as Ok<FixtureRef>).value,
            grade: FixtureScoreGrade.exactScoreline,
            points: total,
          ),
        ],
      );

  // ---------------------------------------------------------------------------
  // POST /rounds/{id}/ledger — PostRoundToLedger (admin-only command)
  // ---------------------------------------------------------------------------
  group('POST /rounds/{id}/ledger', () {
    /// Wires the post use-case over a competition repo carrying the round in
    /// [status] and a score repo seeded with [seededScores].
    Future<({CompositionRoot root, InMemoryLedgerRepository ledger})> rootFor({
      required RoundStatus status,
      List<RoundScore> seededScores = const [],
    }) async {
      final comp = InMemoryCompetitionRepository()
        ..rounds[kRoundId] = roundIn(status);
      final scores = InMemoryScoreRepository();
      if (seededScores.isNotEmpty) {
        await scores.saveRoundScores(seededScores);
      }
      final ledger = InMemoryLedgerRepository();
      final root = CompositionRoot.forTesting(
        postRoundToLedger: PostRoundToLedger(
          competitionRepository: comp,
          scoreRepository: scores,
          ledgerRepository: ledger,
          idGenerator: ScriptedIdGenerator([kEntryId1, kEntryId2]),
          clock: FixedClock(_at),
        ),
      );
      return (root: root, ledger: ledger);
    }

    Future<Response> post(CompositionRoot root, AuthenticatedUser principal) =>
        post_ledger_route.onRequest(
          wireContext(
            root: root,
            principal: principal,
            method: HttpMethod.post,
          ),
          kRoundId,
        );

    test(
      'an admin posts a scored round and gets 200 with appended entries',
      () async {
        final setup = await rootFor(
          status: RoundStatus.scored,
          seededScores: [
            storedScore(kParticipantId, 4),
            storedScore(kOtherParticipantId, 2),
          ],
        );

        final response = await post(setup.root, adminPrincipal());

        expect(response.statusCode, HttpStatus.ok);
        final body = await decodeBody(response);
        expect(body['round_id'], kRoundId);
        final appended = body['appended_entries']! as List<Object?>;
        expect(appended, hasLength(2));
        final first = (appended.first! as Map).cast<String, Object?>();
        expect(first['participant_id'], kParticipantId);
        expect(first['round_id'], kRoundId);
        expect(first['kind'], 'round_score');
        expect(first['amount'], 4);
        expect(first['source_ref'], 'round_score:$kRoundId:$kParticipantId');
        // Never a points/score leak beyond the signed amount + provenance.
        expect(first.containsKey('points'), isFalse);
        final second = (appended[1]! as Map).cast<String, Object?>();
        expect(second['participant_id'], kOtherParticipantId);
        expect(second['amount'], 2);
        // The credits were actually appended to the stream.
        expect(setup.ledger.entries, hasLength(2));
      },
    );

    test('a non-admin caller is rejected 401 (admin-only gate)', () async {
      final setup = await rootFor(
        status: RoundStatus.scored,
        seededScores: [storedScore(kParticipantId, 4)],
      );

      final response = await post(setup.root, userPrincipal());

      expect(response.statusCode, HttpStatus.unauthorized);
      expect((await decodeBody(response))['code'], 'auth.insufficient_role');
      // Nothing was appended on the rejected path (Axiom 2).
      expect(setup.ledger.entries, isEmpty);
    });

    test('posting a not-yet-scored round is rejected 409 '
        'ledger.round_not_scored', () async {
      final setup = await rootFor(status: RoundStatus.locked);
      final response = await post(setup.root, adminPrincipal());

      expect(response.statusCode, HttpStatus.conflict);
      expect((await decodeBody(response))['code'], 'ledger.round_not_scored');
      expect(setup.ledger.entries, isEmpty);
    });

    test('re-posting an already-posted round is idempotent — 200, empty '
        'appended list, no double-credit', () async {
      final setup = await rootFor(
        status: RoundStatus.scored,
        seededScores: [storedScore(kParticipantId, 4)],
      );

      // First post: appends the single credit.
      final first = await post(setup.root, adminPrincipal());
      expect(first.statusCode, HttpStatus.ok);
      expect((await decodeBody(first))['appended_entries'], hasLength(1));
      expect(setup.ledger.entries, hasLength(1));

      // Second post: the dedupe key skips the existing credit — nothing new is
      // appended, no participant is double-credited (Axiom 4).
      final second = await post(setup.root, adminPrincipal());
      expect(second.statusCode, HttpStatus.ok);
      expect((await decodeBody(second))['appended_entries'], isEmpty);
      // Still exactly one row on the stream.
      expect(setup.ledger.entries, hasLength(1));
    });

    test(
      'posting a scored round with no scored participants is 200 + empty',
      () async {
        final setup = await rootFor(status: RoundStatus.scored);
        final response = await post(setup.root, adminPrincipal());

        expect(response.statusCode, HttpStatus.ok);
        expect((await decodeBody(response))['appended_entries'], isEmpty);
        expect(setup.ledger.entries, isEmpty);
      },
    );

    test('a non-POST method is 405', () async {
      final setup = await rootFor(status: RoundStatus.scored);
      final response = await post_ledger_route.onRequest(
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
  // GET /participants/{id}/balance — ReadParticipantLedger.balanceOf (self-read)
  // ---------------------------------------------------------------------------
  group('GET /participants/{id}/balance', () {
    /// Wires the read use-case over a ledger seeded with [entries] (via a real
    /// admin post is unnecessary here — we seed the stream directly) and a
    /// participant reader knowing kParticipantId (owned by kUserId) and
    /// kOtherParticipantId (owned by kOtherUserId).
    Future<({CompositionRoot root, InMemoryLedgerRepository ledger})> rootFor({
      List<PointEntry> entries = const [],
    }) async {
      final ledger = InMemoryLedgerRepository();
      if (entries.isNotEmpty) {
        await ledger.appendEntries(entries);
      }
      final reader = InMemoryParticipantReader()
        ..add(participant(kParticipantId, kUserId))
        ..add(participant(kOtherParticipantId, kOtherUserId));
      final root = CompositionRoot.forTesting(
        readParticipantLedger: ReadParticipantLedger(
          participantReader: reader,
          ledgerRepository: ledger,
        ),
      );
      return (root: root, ledger: ledger);
    }

    /// A round_score credit for [participantId] worth [amount], stamped now,
    /// for round [roundIdStr] (defaults to the harness's [kRoundId]). Pass a
    /// distinct [roundIdStr] when seeding more than one credit for the same
    /// participant — a round_score entry is unique per (participant, round),
    /// so two credits for the same round would dedupe to one (a re-post), not
    /// add up.
    PointEntry credit(
      String entryId,
      String participantId,
      int amount, {
      String roundIdStr = kRoundId,
    }) =>
        (PointEntry.create(
                  id: (PointEntryId.tryParse(entryId) as Ok<PointEntryId>)
                      .value,
                  participantId:
                      (ParticipantId.tryParse(participantId)
                              as Ok<ParticipantId>)
                          .value,
                  roundId: (RoundId.tryParse(roundIdStr) as Ok<RoundId>).value,
                  kind: EntryKind.roundScore,
                  amount: amount,
                  sourceRef: 'round_score:$roundIdStr:$participantId',
                  occurredAt: _at,
                )
                as Ok<PointEntry>)
            .value;

    Future<Response> get(
      CompositionRoot root,
      AuthenticatedUser principal,
      String participantId,
    ) => balance_route.onRequest(
      wireContext(root: root, principal: principal, method: HttpMethod.get),
      participantId,
    );

    test('the owner reads their projected balance and gets 200', () async {
      final setup = await rootFor(
        entries: [
          credit(kEntryId1, kParticipantId, 4),
          credit(kEntryId2, kParticipantId, 3, roundIdStr: kRoundId2),
        ],
      );

      final response = await get(setup.root, userPrincipal(), kParticipantId);

      expect(response.statusCode, HttpStatus.ok);
      final body = await decodeBody(response);
      expect(body['participant_id'], kParticipantId);
      expect(body['balance'], 7);
      expect(body['entry_count'], 2);
    });

    test('an owner with no entries gets 200 with a zero balance', () async {
      final setup = await rootFor();
      final response = await get(setup.root, userPrincipal(), kParticipantId);

      expect(response.statusCode, HttpStatus.ok);
      final body = await decodeBody(response);
      expect(body['balance'], 0);
      expect(body['entry_count'], 0);
    });

    test('reading a participant owned by someone else is rejected 401 '
        'ledger.participant_not_found', () async {
      final setup = await rootFor(
        entries: [credit(kEntryId1, kOtherParticipantId, 5)],
      );
      // The caller (kUserId) does not own kOtherParticipantId.
      final response = await get(
        setup.root,
        userPrincipal(),
        kOtherParticipantId,
      );

      expect(response.statusCode, HttpStatus.unauthorized);
      expect(
        (await decodeBody(response))['code'],
        'ledger.participant_not_found',
      );
    });

    test('reading an unknown participant is rejected 401 (same as foreign — no '
        'enumeration oracle)', () async {
      final setup = await rootFor();
      const kUnknownId = 'ffffffff-ffff-ffff-ffff-ffffffffffff';
      final response = await get(setup.root, userPrincipal(), kUnknownId);

      expect(response.statusCode, HttpStatus.unauthorized);
      expect(
        (await decodeBody(response))['code'],
        'ledger.participant_not_found',
      );
    });

    test('a non-GET method is 405', () async {
      final setup = await rootFor();
      final response = await balance_route.onRequest(
        wireContext(
          root: setup.root,
          principal: userPrincipal(),
          method: HttpMethod.post,
        ),
        kParticipantId,
      );
      expect(response.statusCode, HttpStatus.methodNotAllowed);
    });
  });

  // ---------------------------------------------------------------------------
  // GET /participants/{id}/entries — ReadParticipantLedger.entriesOf (self-read)
  // ---------------------------------------------------------------------------
  group('GET /participants/{id}/entries', () {
    Future<({CompositionRoot root, InMemoryLedgerRepository ledger})> rootFor({
      List<PointEntry> entries = const [],
    }) async {
      final ledger = InMemoryLedgerRepository();
      if (entries.isNotEmpty) {
        await ledger.appendEntries(entries);
      }
      final reader = InMemoryParticipantReader()
        ..add(participant(kParticipantId, kUserId))
        ..add(participant(kOtherParticipantId, kOtherUserId));
      final root = CompositionRoot.forTesting(
        readParticipantLedger: ReadParticipantLedger(
          participantReader: reader,
          ledgerRepository: ledger,
        ),
      );
      return (root: root, ledger: ledger);
    }

    PointEntry creditAt(
      String entryId,
      String participantId,
      int amount,
      DateTime at,
    ) =>
        (PointEntry.create(
                  id: (PointEntryId.tryParse(entryId) as Ok<PointEntryId>)
                      .value,
                  participantId:
                      (ParticipantId.tryParse(participantId)
                              as Ok<ParticipantId>)
                          .value,
                  roundId: roundId,
                  kind: EntryKind.roundScore,
                  amount: amount,
                  sourceRef: 'round_score:$entryId:$participantId',
                  occurredAt: at,
                )
                as Ok<PointEntry>)
            .value;

    Future<Response> get(
      CompositionRoot root,
      AuthenticatedUser principal,
      String participantId,
    ) => entries_route.onRequest(
      wireContext(root: root, principal: principal, method: HttpMethod.get),
      participantId,
    );

    test('the owner reads their append-only stream (200, ordered)', () async {
      final earlier = DateTime.utc(2026, 7, 20, 9);
      final later = DateTime.utc(2026, 7, 20, 10);
      final setup = await rootFor(
        entries: [
          // Seed out of order; the stream is returned occurred-at ascending.
          creditAt(kEntryId2, kParticipantId, 3, later),
          creditAt(kEntryId1, kParticipantId, 4, earlier),
        ],
      );

      final response = await get(setup.root, userPrincipal(), kParticipantId);

      expect(response.statusCode, HttpStatus.ok);
      final body = await decodeBody(response);
      expect(body['participant_id'], kParticipantId);
      final list = body['entries']! as List<Object?>;
      expect(list, hasLength(2));
      final first = (list.first! as Map).cast<String, Object?>();
      final second = (list[1]! as Map).cast<String, Object?>();
      // Ordered by occurred_at ascending: the earlier (amount 4) comes first.
      expect(first['amount'], 4);
      expect(second['amount'], 3);
      expect(first['kind'], 'round_score');
    });

    test('an owner with no entries gets 200 with an empty list', () async {
      final setup = await rootFor();
      final response = await get(setup.root, userPrincipal(), kParticipantId);

      expect(response.statusCode, HttpStatus.ok);
      expect((await decodeBody(response))['entries'], isEmpty);
    });

    test('reading a foreign participant is rejected 401 '
        'ledger.participant_not_found', () async {
      final setup = await rootFor(
        entries: [creditAt(kEntryId1, kOtherParticipantId, 5, _at)],
      );
      final response = await get(
        setup.root,
        userPrincipal(),
        kOtherParticipantId,
      );

      expect(response.statusCode, HttpStatus.unauthorized);
      expect(
        (await decodeBody(response))['code'],
        'ledger.participant_not_found',
      );
    });

    test('a non-GET method is 405', () async {
      final setup = await rootFor();
      final response = await entries_route.onRequest(
        wireContext(
          root: setup.root,
          principal: userPrincipal(),
          method: HttpMethod.post,
        ),
        kParticipantId,
      );
      expect(response.statusCode, HttpStatus.methodNotAllowed);
    });
  });
}

/// A fixed UTC instant used for clock-stamped writes in these tests.
final DateTime _at = DateTime.utc(2026, 7, 20, 9, 30);
