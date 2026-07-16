import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import '../competition/fake_competition_repository.dart';
import '../competition/fakes.dart';
import '../scoring/fakes.dart';
import 'fakes.dart';

const _round = '33333333-3333-3333-3333-333333333333';
const _season = '55555555-5555-5555-5555-555555555555';
const _p1 = '22222222-2222-2222-2222-222222222222';
const _p2 = '77777777-7777-7777-7777-777777777777';
const _admin = 'dddddddd-dddd-dddd-dddd-dddddddddddd';
const _user = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee';
const _e1 = '11111111-1111-1111-1111-111111111111';
const _e2 = '99999999-9999-9999-9999-999999999999';
const _e3 = 'cccccccc-cccc-cccc-cccc-cccccccccccc';

void main() {
  late FakeCompetitionRepository competition;
  late FakeScoreRepository scores;
  late FakeLedgerRepository ledger;
  late FakeIdGenerator ids;
  late PostRoundToLedger useCase;

  void seedRound(RoundStatus status) {
    competition.seedRound(
      ledgerRound(id: _round, seasonId: _season, status: status),
    );
  }

  void seedTwoScores() {
    // Note: FakeScoreRepository seeds via saveRoundScores in setUp-driven tests.
    scores.saveRoundScores([
      ledgerScore(roundId: _round, participantId: _p1, total: 4),
      ledgerScore(roundId: _round, participantId: _p2, total: 1),
    ]);
  }

  setUp(() {
    competition = FakeCompetitionRepository();
    scores = FakeScoreRepository();
    ledger = FakeLedgerRepository();
    // Enough ids for two posts of two participants (dedupe means the 2nd post's
    // ids are simply unused — the last id repeats harmlessly).
    ids = FakeIdGenerator([_e1, _e2, _e3]);
    useCase = PostRoundToLedger(
      competitionRepository: competition,
      scoreRepository: scores,
      ledgerRepository: ledger,
      idGenerator: ids,
      clock: FixedClock(DateTime.utc(2026, 7, 11, 12)),
    );
  });

  test('an admin posts a scored round: one credit per participant', () async {
    seedRound(RoundStatus.scored);
    seedTwoScores();

    final r = await useCase.call(
      principal: adminPrincipal(_admin),
      roundId: _round,
    );

    expect(r, isA<Ok<List<PointEntry>>>());
    final appended = (r as Ok<List<PointEntry>>).value;
    expect(appended.length, 2);
    expect(ledger.count, 2);
    // Every appended entry is a non-negative round_score credit carrying the
    // score's totalPoints, keyed to this round.
    for (final e in appended) {
      expect(e.kind, EntryKind.roundScore);
      expect(e.roundId, const RoundId(_round));
      expect(e.occurredAt, DateTime.utc(2026, 7, 11, 12));
      expect(e.amount, greaterThanOrEqualTo(0));
      expect(e.sourceRef, contains(_round));
    }
    final byParticipant = {
      for (final e in appended) e.participantId.value: e.amount,
    };
    expect(byParticipant[_p1], 4);
    expect(byParticipant[_p2], 1);
  });

  test(
    're-posting the same scored round is idempotent: nothing new, no double-credit',
    () async {
      seedRound(RoundStatus.scored);
      seedTwoScores();

      final first = await useCase.call(
        principal: adminPrincipal(_admin),
        roundId: _round,
      );
      expect((first as Ok<List<PointEntry>>).value.length, 2);
      expect(ledger.count, 2);

      // Replay: same round, same scores. The dedupe key skips every entry.
      final second = await useCase.call(
        principal: adminPrincipal(_admin),
        roundId: _round,
      );
      expect(second, isA<Ok<List<PointEntry>>>());
      expect((second as Ok<List<PointEntry>>).value, isEmpty);
      // Still exactly two crediting rows — no double-credit (Axiom 4).
      expect(ledger.count, 2);
    },
  );

  test(
    'a non-admin caller is rejected (Axiom 2: client never posts points)',
    () async {
      seedRound(RoundStatus.scored);
      seedTwoScores();

      final r = await useCase.call(
        principal: userPrincipal(_user),
        roundId: _round,
      );

      final err = (r as Err<List<PointEntry>>).error;
      expect(err.kind, ErrorKind.authorization);
      expect(ledger.count, 0);
    },
  );

  test('a round that is not yet scored is refused', () async {
    seedRound(RoundStatus.locked);
    seedTwoScores();

    final r = await useCase.call(
      principal: adminPrincipal(_admin),
      roundId: _round,
    );

    final err = (r as Err<List<PointEntry>>).error;
    expect(err.kind, ErrorKind.invariant);
    expect(err.code, 'ledger.round_not_scored');
    expect(ledger.count, 0);
  });

  test('an open round is refused too', () async {
    seedRound(RoundStatus.open);
    seedTwoScores();

    final r = await useCase.call(
      principal: adminPrincipal(_admin),
      roundId: _round,
    );

    expect((r as Err<List<PointEntry>>).error.code, 'ledger.round_not_scored');
  });

  test('a missing round propagates the not-found invariant', () async {
    // no seedRound
    final r = await useCase.call(
      principal: adminPrincipal(_admin),
      roundId: _round,
    );

    expect(
      (r as Err<List<PointEntry>>).error.code,
      'competition.round_not_found',
    );
  });

  test(
    'a scored round with no predictions posts zero entries (legit empty)',
    () async {
      seedRound(RoundStatus.scored);
      // no scores seeded

      final r = await useCase.call(
        principal: adminPrincipal(_admin),
        roundId: _round,
      );

      expect(r, isA<Ok<List<PointEntry>>>());
      expect((r as Ok<List<PointEntry>>).value, isEmpty);
      expect(ledger.count, 0);
    },
  );

  test('a malformed round id is a validation error', () async {
    final r = await useCase.call(
      principal: adminPrincipal(_admin),
      roundId: 'not-a-uuid',
    );

    expect((r as Err<List<PointEntry>>).error.kind, ErrorKind.validation);
    expect(ledger.count, 0);
  });

  test('a transient score-read failure propagates unchanged', () async {
    seedRound(RoundStatus.scored);
    scores.failNextWith(
      const AppError.transient('scoring.db_unavailable', 'db down'),
    );

    final r = await useCase.call(
      principal: adminPrincipal(_admin),
      roundId: _round,
    );

    final err = (r as Err<List<PointEntry>>).error;
    expect(err.kind, ErrorKind.transient);
    expect(err.code, 'scoring.db_unavailable');
    expect(ledger.count, 0);
  });

  test('a transient append failure propagates unchanged', () async {
    seedRound(RoundStatus.scored);
    seedTwoScores();
    ledger.failNextWith(
      const AppError.transient('ledger.db_unavailable', 'db down'),
    );

    final r = await useCase.call(
      principal: adminPrincipal(_admin),
      roundId: _round,
    );

    final err = (r as Err<List<PointEntry>>).error;
    expect(err.kind, ErrorKind.transient);
    expect(err.code, 'ledger.db_unavailable');
    expect(ledger.count, 0);
  });
}
