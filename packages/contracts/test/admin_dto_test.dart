import 'package:contracts/contracts.dart';
import 'package:test/test.dart';

const _entry = AuditEntryDto(
  id: '55555555-5555-5555-5555-555555555555',
  actorId: '11111111-1111-1111-1111-111111111111',
  action: 'user_suspended',
  targetRef: '22222222-2222-2222-2222-222222222222',
  reason: 'abusive behaviour',
  occurredAt: '2026-07-13T12:00:00.000Z',
);

void main() {
  group('SuspendUserRequestDto', () {
    const req = SuspendUserRequestDto(reason: 'violated the rules');

    test('round-trips through JSON with snake_case wire keys', () {
      final json = req.toJson();
      expect(json.keys, containsAll(<String>['schema_version', 'reason']));
      expect(SuspendUserRequestDto.fromJson(json), req);
    });

    test('defaults schema_version for a legacy payload lacking the field', () {
      final json = req.toJson()..remove('schema_version');
      expect(SuspendUserRequestDto.fromJson(json).schemaVersion, 1);
    });

    test('a missing reason parses as null (use-case reports the failure)', () {
      final parsed = SuspendUserRequestDto.fromJson(<String, Object?>{
        'schema_version': 1,
      });
      expect(parsed.reason, isNull);
    });

    test('carries no points field on the wire', () {
      expect(req.toJson().keys, isNot(contains('points')));
      expect(req.toJson().keys, isNot(contains('amount')));
    });

    test('value equality over reason + schema version', () {
      expect(
        const SuspendUserRequestDto(reason: 'x'),
        const SuspendUserRequestDto(reason: 'x'),
      );
      expect(
        const SuspendUserRequestDto(reason: 'x'),
        isNot(const SuspendUserRequestDto(reason: 'y')),
      );
    });
  });

  group('UserSanctionResultDto', () {
    const result = UserSanctionResultDto(
      userId: '22222222-2222-2222-2222-222222222222',
      status: 'suspended',
    );

    test('round-trips through JSON with snake_case wire keys', () {
      final json = result.toJson();
      expect(
        json.keys,
        containsAll(<String>['schema_version', 'user_id', 'status']),
      );
      expect(UserSanctionResultDto.fromJson(json), result);
    });

    test('defaults schema_version for a legacy payload', () {
      final json = result.toJson()..remove('schema_version');
      expect(UserSanctionResultDto.fromJson(json).schemaVersion, 1);
    });

    test('carries no points field', () {
      expect(result.toJson().keys, isNot(contains('points')));
    });

    test('value equality over all fields', () {
      expect(
        const UserSanctionResultDto(userId: 'a', status: 'active'),
        const UserSanctionResultDto(userId: 'a', status: 'active'),
      );
      expect(
        const UserSanctionResultDto(userId: 'a', status: 'active'),
        isNot(const UserSanctionResultDto(userId: 'a', status: 'suspended')),
      );
    });
  });

  group('AuditEntryDto', () {
    test('round-trips through JSON with snake_case wire keys', () {
      final json = _entry.toJson();
      expect(
        json.keys,
        containsAll(<String>[
          'schema_version',
          'id',
          'actor_id',
          'action',
          'target_ref',
          'reason',
          'occurred_at',
        ]),
      );
      expect(AuditEntryDto.fromJson(json), _entry);
    });

    test('defaults schema_version for a legacy payload', () {
      final json = _entry.toJson()..remove('schema_version');
      expect(AuditEntryDto.fromJson(json).schemaVersion, 1);
    });

    test('omits the reason key entirely when null', () {
      const noReason = AuditEntryDto(
        id: '55555555-5555-5555-5555-555555555555',
        actorId: '11111111-1111-1111-1111-111111111111',
        action: 'round_scored',
        targetRef: 'round:33333333-3333-3333-3333-333333333333',
        occurredAt: '2026-07-13T12:00:00.000Z',
      );
      final json = noReason.toJson();
      expect(json.containsKey('reason'), isFalse);
      // ...and re-parses back to an equal value (reason stays null).
      expect(AuditEntryDto.fromJson(json), noReason);
    });

    test('carries the action as a stable wire token, not an enum name', () {
      expect(_entry.toJson()['action'], 'user_suspended');
    });

    test('carries no points field', () {
      expect(_entry.toJson().keys, isNot(contains('points')));
      expect(_entry.toJson().keys, isNot(contains('amount')));
    });

    test('value equality is sensitive to every field incl. reason', () {
      expect(AuditEntryDto.fromJson(_entry.toJson()), _entry);
      final other = AuditEntryDto(
        id: _entry.id,
        actorId: _entry.actorId,
        action: _entry.action,
        targetRef: _entry.targetRef,
        reason: 'different reason',
        occurredAt: _entry.occurredAt,
      );
      expect(other, isNot(_entry));
    });
  });

  group('AuditLogDto', () {
    test('round-trips a populated trail through JSON', () {
      const log = AuditLogDto(entries: [_entry]);
      final json = log.toJson();
      expect(json.keys, containsAll(<String>['schema_version', 'entries']));
      expect(AuditLogDto.fromJson(json), log);
    });

    test('an empty trail is legitimate (never an error)', () {
      const empty = AuditLogDto(entries: []);
      expect(AuditLogDto.fromJson(empty.toJson()), empty);
      expect(empty.entries, isEmpty);
    });

    test('equality is order-significant', () {
      final second = AuditEntryDto(
        id: '66666666-6666-6666-6666-666666666666',
        actorId: _entry.actorId,
        action: 'user_reinstated',
        targetRef: _entry.targetRef,
        occurredAt: '2026-07-13T13:00:00.000Z',
      );
      final a = AuditLogDto(entries: [_entry, second]);
      final b = AuditLogDto(entries: [second, _entry]);
      expect(a, isNot(b));
    });

    test('defaults schema_version for a legacy payload', () {
      const log = AuditLogDto(entries: [_entry]);
      final json = log.toJson()..remove('schema_version');
      expect(AuditLogDto.fromJson(json).schemaVersion, 1);
    });
  });
}
