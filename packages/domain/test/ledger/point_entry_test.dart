import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

const _entryId = '55555555-5555-5555-5555-555555555555';
const _participant = '44444444-4444-4444-4444-444444444444';
const _round = '33333333-3333-3333-3333-333333333333';

PointEntryId _id() => const PointEntryId(_entryId);
ParticipantId _pid() => const ParticipantId(_participant);
RoundId _rid() => const RoundId(_round);
DateTime _now() => DateTime.utc(2026, 7, 11, 12);

void main() {
  group('PointEntryId', () {
    test('tryParse accepts a canonical UUID', () {
      final result = PointEntryId.tryParse(_entryId);
      expect((result as Ok<PointEntryId>).value.value, _entryId);
    });

    test('tryParse rejects an empty id', () {
      final result = PointEntryId.tryParse('');
      expect(
        (result as Err<PointEntryId>).error.code,
        'ledger.point_entry_id_empty',
      );
    });

    test('tryParse rejects a malformed id', () {
      final result = PointEntryId.tryParse('not-a-uuid');
      expect(
        (result as Err<PointEntryId>).error.code,
        'ledger.point_entry_id_malformed',
      );
      expect(result.error.kind, ErrorKind.validation);
    });
  });

  group('EntryKind', () {
    test('wire tokens are stable and round-trip via tryParse', () {
      for (final kind in EntryKind.values) {
        final parsed = EntryKind.tryParse(kind.wireValue);
        expect((parsed as Ok<EntryKind>).value, kind);
      }
    });

    test('round_score requires a non-negative amount and is deduped', () {
      expect(EntryKind.roundScore.requiresNonNegativeAmount, isTrue);
      expect(EntryKind.roundScore.isDedupedPerRound, isTrue);
      expect(EntryKind.roundScore.wireValue, 'round_score');
    });

    test('correction allows negative amounts and is append-many', () {
      expect(EntryKind.correction.requiresNonNegativeAmount, isFalse);
      expect(EntryKind.correction.isDedupedPerRound, isFalse);
      expect(EntryKind.correction.wireValue, 'correction');
    });

    test('rejects an unknown / null token', () {
      expect(
        (EntryKind.tryParse('bonus') as Err<EntryKind>).error.code,
        'ledger.entry_kind_unknown',
      );
      expect(
        (EntryKind.tryParse(null) as Err<EntryKind>).error.code,
        'ledger.entry_kind_unknown',
      );
    });
  });

  group('PointEntry.create', () {
    test('builds a valid round_score credit', () {
      final result = PointEntry.create(
        id: _id(),
        participantId: _pid(),
        roundId: _rid(),
        kind: EntryKind.roundScore,
        amount: 7,
        sourceRef: 'round_score:$_round',
        occurredAt: _now(),
      );
      final entry = (result as Ok<PointEntry>).value;
      expect(entry.amount, 7);
      expect(entry.kind, EntryKind.roundScore);
      expect(entry.sourceRef, 'round_score:$_round');
      expect(entry.occurredAt, _now());
    });

    test('allows a zero round_score credit', () {
      final result = PointEntry.create(
        id: _id(),
        participantId: _pid(),
        roundId: _rid(),
        kind: EntryKind.roundScore,
        amount: 0,
        sourceRef: 'round_score:$_round',
        occurredAt: _now(),
      );
      expect((result as Ok<PointEntry>).value.amount, 0);
    });

    test('rejects a negative round_score credit', () {
      final result = PointEntry.create(
        id: _id(),
        participantId: _pid(),
        roundId: _rid(),
        kind: EntryKind.roundScore,
        amount: -1,
        sourceRef: 'round_score:$_round',
        occurredAt: _now(),
      );
      final error = (result as Err<PointEntry>).error;
      expect(error.code, 'ledger.entry_amount_negative');
      expect(error.kind, ErrorKind.validation);
    });

    test('allows a negative correction (compensating entry — Axiom 5)', () {
      final result = PointEntry.create(
        id: _id(),
        participantId: _pid(),
        roundId: _rid(),
        kind: EntryKind.correction,
        amount: -3,
        sourceRef: 'correction:typo-fix',
        occurredAt: _now(),
      );
      expect((result as Ok<PointEntry>).value.amount, -3);
    });

    test('rejects a non-UTC occurredAt', () {
      final result = PointEntry.create(
        id: _id(),
        participantId: _pid(),
        roundId: _rid(),
        kind: EntryKind.roundScore,
        amount: 5,
        sourceRef: 'round_score:$_round',
        occurredAt: DateTime(2026, 7, 11, 12), // local, not UTC
      );
      expect(
        (result as Err<PointEntry>).error.code,
        'ledger.entry_occurred_at_not_utc',
      );
    });

    test('rejects an empty source reference', () {
      final result = PointEntry.create(
        id: _id(),
        participantId: _pid(),
        roundId: _rid(),
        kind: EntryKind.roundScore,
        amount: 5,
        sourceRef: '',
        occurredAt: _now(),
      );
      expect(
        (result as Err<PointEntry>).error.code,
        'ledger.entry_source_ref_empty',
      );
    });

    test('exposes no mutation API (append-only — compile-time guarantee)', () {
      // A PointEntry has no copyWith/setter/transition; the only construction
      // paths are `create` (validated) and `fromStored` (trusted rehydration).
      // This test documents the invariant and asserts value-equality holds.
      final a =
          (PointEntry.create(
                    id: _id(),
                    participantId: _pid(),
                    roundId: _rid(),
                    kind: EntryKind.roundScore,
                    amount: 7,
                    sourceRef: 'round_score:$_round',
                    occurredAt: _now(),
                  )
                  as Ok<PointEntry>)
              .value;
      final b = PointEntry.fromStored(
        id: _id(),
        participantId: _pid(),
        roundId: _rid(),
        kind: EntryKind.roundScore,
        amount: 7,
        sourceRef: 'round_score:$_round',
        occurredAt: _now(),
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });
}
