import 'package:contracts/contracts.dart';
import 'package:test/test.dart';

const _entry = PointEntryDto(
  id: '55555555-5555-5555-5555-555555555555',
  participantId: '44444444-4444-4444-4444-444444444444',
  roundId: '33333333-3333-3333-3333-333333333333',
  kind: 'round_score',
  amount: 7,
  sourceRef: 'round_score:33333333-3333-3333-3333-333333333333',
  occurredAt: '2026-07-11T12:00:00.000Z',
);

void main() {
  group('PointEntryDto', () {
    test('round-trips through JSON with snake_case wire keys', () {
      final json = _entry.toJson();
      expect(
        json.keys,
        containsAll(<String>[
          'schema_version',
          'id',
          'participant_id',
          'round_id',
          'kind',
          'amount',
          'source_ref',
          'occurred_at',
        ]),
      );
      expect(PointEntryDto.fromJson(json), _entry);
    });

    test('defaults schema_version for a legacy payload lacking the field', () {
      final json = _entry.toJson()..remove('schema_version');
      final parsed = PointEntryDto.fromJson(json);
      expect(parsed.schemaVersion, 1);
    });

    test('carries a signed amount (correction may be negative)', () {
      const correction = PointEntryDto(
        id: '55555555-5555-5555-5555-555555555556',
        participantId: '44444444-4444-4444-4444-444444444444',
        roundId: '33333333-3333-3333-3333-333333333333',
        kind: 'correction',
        amount: -4,
        sourceRef: 'correction:typo',
        occurredAt: '2026-07-11T13:00:00.000Z',
      );
      expect(PointEntryDto.fromJson(correction.toJson()).amount, -4);
    });

    test('value equality is by field, not identity', () {
      final json = _entry.toJson();
      expect(PointEntryDto.fromJson(json), _entry);
      expect(PointEntryDto.fromJson(json).hashCode, _entry.hashCode);
    });
  });

  group('BalanceDto', () {
    test('round-trips with snake_case keys and defaults schema_version', () {
      const dto = BalanceDto(
        participantId: '44444444-4444-4444-4444-444444444444',
        balance: 13,
        entryCount: 2,
      );
      final json = dto.toJson();
      expect(
        json.keys,
        containsAll(<String>[
          'schema_version',
          'participant_id',
          'balance',
          'entry_count',
        ]),
      );
      expect(BalanceDto.fromJson(json), dto);
      final legacy = json..remove('schema_version');
      expect(BalanceDto.fromJson(legacy).schemaVersion, 1);
    });
  });

  group('ParticipantEntriesDto', () {
    test('round-trips a list of entries, order-significant', () {
      const dto = ParticipantEntriesDto(
        participantId: '44444444-4444-4444-4444-444444444444',
        entries: [_entry],
      );
      final json = dto.toJson();
      expect(json.keys, containsAll(<String>['participant_id', 'entries']));
      expect(ParticipantEntriesDto.fromJson(json), dto);
    });

    test('an empty entries list round-trips', () {
      const dto = ParticipantEntriesDto(
        participantId: '44444444-4444-4444-4444-444444444444',
        entries: [],
      );
      expect(ParticipantEntriesDto.fromJson(dto.toJson()), dto);
    });
  });

  group('PostRoundToLedgerResponseDto', () {
    test('round-trips appended entries', () {
      const dto = PostRoundToLedgerResponseDto(
        roundId: '33333333-3333-3333-3333-333333333333',
        appendedEntries: [_entry],
      );
      final json = dto.toJson();
      expect(json.keys, containsAll(<String>['round_id', 'appended_entries']));
      expect(PostRoundToLedgerResponseDto.fromJson(json), dto);
    });

    test('an empty appended list (idempotent replay) round-trips', () {
      const dto = PostRoundToLedgerResponseDto(
        roundId: '33333333-3333-3333-3333-333333333333',
        appendedEntries: [],
      );
      expect(PostRoundToLedgerResponseDto.fromJson(dto.toJson()), dto);
      expect(dto.appendedEntries, isEmpty);
    });
  });

  group('no leakage', () {
    test('the ledger read shapes never expose a group reference', () {
      final entryJson = _entry.toJson();
      expect(entryJson.keys, isNot(contains('group_id')));
      const balance = BalanceDto(participantId: 'p', balance: 0, entryCount: 0);
      expect(balance.toJson().keys, isNot(contains('group_id')));
    });
  });
}
