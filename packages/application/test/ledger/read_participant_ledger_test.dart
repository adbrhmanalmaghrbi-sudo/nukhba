import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import '../competition/fakes.dart';
import 'fakes.dart';

const _round = '33333333-3333-3333-3333-333333333333';
const _season = '55555555-5555-5555-5555-555555555555';
const _partId = '66666666-6666-6666-6666-666666666666';
const _otherPartId = '88888888-8888-8888-8888-888888888888';
const _user = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee';
const _outsider = 'ffffffff-ffff-ffff-ffff-ffffffffffff';
const _e1 = '11111111-1111-1111-1111-111111111111';
const _e2 = '99999999-9999-9999-9999-999999999999';

void main() {
  late FakeParticipantReader participants;
  late FakeLedgerRepository ledger;
  late ReadParticipantLedger useCase;

  void seedOwnParticipant() {
    participants.seed(
      ledgerParticipant(id: _partId, seasonId: _season, userId: _user),
    );
  }

  void seedOwnEntries() {
    // Two credits (4 then a correction of -1), stamped in stream order.
    ledger.appendEntries([
      ledgerEntry(
        id: _e1,
        participantId: _partId,
        roundId: _round,
        amount: 4,
        occurredAt: DateTime.utc(2026, 7, 11, 10),
      ),
      ledgerEntry(
        id: _e2,
        participantId: _partId,
        roundId: _round,
        amount: -1,
        kind: EntryKind.correction,
        sourceRef: 'correction:manual-fix-1',
        occurredAt: DateTime.utc(2026, 7, 11, 11),
      ),
    ]);
  }

  setUp(() {
    participants = FakeParticipantReader();
    ledger = FakeLedgerRepository();
    useCase = ReadParticipantLedger(
      participantReader: participants,
      ledgerRepository: ledger,
    );
  });

  test('owner reads their projected balance (sum over the stream)', () async {
    seedOwnParticipant();
    seedOwnEntries();

    final r = await useCase.balanceOf(
      principal: userPrincipal(_user),
      participantId: _partId,
    );

    expect(r, isA<Ok<LedgerBalance>>());
    final balance = (r as Ok<LedgerBalance>).value;
    expect(balance.participantId, const ParticipantId(_partId));
    expect(balance.balance, 3); // 4 + (-1)
    expect(balance.entryCount, 2);
  });

  test('owner reads their entry stream in occurred-at then id order', () async {
    seedOwnParticipant();
    seedOwnEntries();

    final r = await useCase.entriesOf(
      principal: userPrincipal(_user),
      participantId: _partId,
    );

    final entries = (r as Ok<List<PointEntry>>).value;
    expect(entries.map((e) => e.id.value), [_e1, _e2]);
    expect(entries.first.kind, EntryKind.roundScore);
    expect(entries.last.kind, EntryKind.correction);
  });

  test(
    'a caller cannot read a foreign participant (reported as not-found)',
    () async {
      // Participant owned by _user, but the outsider asks for it.
      seedOwnParticipant();
      seedOwnEntries();

      final r = await useCase.balanceOf(
        principal: userPrincipal(_outsider),
        participantId: _partId,
      );

      final err = (r as Err<LedgerBalance>).error;
      expect(err.kind, ErrorKind.authorization);
      expect(err.code, 'ledger.participant_not_found');
    },
  );

  test(
    'an unknown participant id is reported identically to a foreign one',
    () async {
      // Nothing seeded — id resolves to null.
      final r = await useCase.entriesOf(
        principal: userPrincipal(_user),
        participantId: _otherPartId,
      );

      final err = (r as Err<List<PointEntry>>).error;
      expect(err.kind, ErrorKind.authorization);
      expect(err.code, 'ledger.participant_not_found');
    },
  );

  test(
    'an owner with no movements projects a zero balance (empty stream)',
    () async {
      seedOwnParticipant();
      // no entries seeded

      final r = await useCase.balanceOf(
        principal: userPrincipal(_user),
        participantId: _partId,
      );

      final balance = (r as Ok<LedgerBalance>).value;
      expect(balance.balance, 0);
      expect(balance.entryCount, 0);
    },
  );

  test('a malformed participant id is a validation error', () async {
    final r = await useCase.entriesOf(
      principal: userPrincipal(_user),
      participantId: 'not-a-uuid',
    );

    expect((r as Err<List<PointEntry>>).error.kind, ErrorKind.validation);
  });

  test('a transient participant-read failure propagates unchanged', () async {
    participants.failNextWith(
      const AppError.transient('competition.db_unavailable', 'db down'),
    );

    final r = await useCase.balanceOf(
      principal: userPrincipal(_user),
      participantId: _partId,
    );

    final err = (r as Err<LedgerBalance>).error;
    expect(err.kind, ErrorKind.transient);
    expect(err.code, 'competition.db_unavailable');
  });

  test('a transient ledger-read failure propagates unchanged', () async {
    seedOwnParticipant();
    ledger.failNextWith(
      const AppError.transient('ledger.db_unavailable', 'db down'),
    );

    final r = await useCase.entriesOf(
      principal: userPrincipal(_user),
      participantId: _partId,
    );

    final err = (r as Err<List<PointEntry>>).error;
    expect(err.kind, ErrorKind.transient);
    expect(err.code, 'ledger.db_unavailable');
  });
}
