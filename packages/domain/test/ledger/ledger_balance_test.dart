import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

const _participantA = '44444444-4444-4444-4444-444444444444';
const _participantB = '99999999-9999-9999-9999-999999999999';
const _round1 = '33333333-3333-3333-3333-333333333333';
const _round2 = '22222222-2222-2222-2222-222222222222';

var _seq = 0;

PointEntry _entry(
  String participant,
  String round,
  EntryKind kind,
  int amount,
) {
  _seq++;
  final hex = _seq.toRadixString(16).padLeft(12, '0');
  return PointEntry.fromStored(
    id: PointEntryId('55555555-5555-5555-5555-$hex'),
    participantId: ParticipantId(participant),
    roundId: RoundId(round),
    kind: kind,
    amount: amount,
    sourceRef: '$round:${kind.wireValue}',
    occurredAt: DateTime.utc(2026, 7, 11, 12, _seq),
  );
}

void main() {
  group('LedgerBalance.project', () {
    test('empty stream projects a zero balance', () {
      final result = LedgerBalance.project(
        participantId: const ParticipantId(_participantA),
        entries: const [],
      );
      final balance = (result as Ok<LedgerBalance>).value;
      expect(balance.balance, 0);
      expect(balance.entryCount, 0);
      expect(balance.participantId.value, _participantA);
    });

    test('sums round_score credits across rounds', () {
      final result = LedgerBalance.project(
        participantId: const ParticipantId(_participantA),
        entries: [
          _entry(_participantA, _round1, EntryKind.roundScore, 5),
          _entry(_participantA, _round2, EntryKind.roundScore, 8),
        ],
      );
      final balance = (result as Ok<LedgerBalance>).value;
      expect(balance.balance, 13);
      expect(balance.entryCount, 2);
    });

    test('a negative correction nets against the original credit', () {
      final result = LedgerBalance.project(
        participantId: const ParticipantId(_participantA),
        entries: [
          _entry(_participantA, _round1, EntryKind.roundScore, 10),
          _entry(_participantA, _round1, EntryKind.correction, -4),
        ],
      );
      final balance = (result as Ok<LedgerBalance>).value;
      expect(balance.balance, 6);
      expect(balance.entryCount, 2);
    });

    test('rejects a stream mixing another participant\'s entry', () {
      final result = LedgerBalance.project(
        participantId: const ParticipantId(_participantA),
        entries: [
          _entry(_participantA, _round1, EntryKind.roundScore, 5),
          _entry(_participantB, _round1, EntryKind.roundScore, 9),
        ],
      );
      final error = (result as Err<LedgerBalance>).error;
      expect(error.code, 'ledger.balance_foreign_entry');
      expect(error.kind, ErrorKind.invariant);
    });

    test('is deterministic — same stream, same projection', () {
      final entries = [
        _entry(_participantA, _round1, EntryKind.roundScore, 3),
        _entry(_participantA, _round2, EntryKind.roundScore, 4),
      ];
      final a =
          (LedgerBalance.project(
                    participantId: const ParticipantId(_participantA),
                    entries: entries,
                  )
                  as Ok<LedgerBalance>)
              .value;
      final b =
          (LedgerBalance.project(
                    participantId: const ParticipantId(_participantA),
                    entries: entries,
                  )
                  as Ok<LedgerBalance>)
              .value;
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });
}
