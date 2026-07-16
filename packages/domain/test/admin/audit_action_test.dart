import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

void main() {
  group('AuditAction wire tokens', () {
    test('every value has a stable snake_case token and round-trips', () {
      for (final action in AuditAction.values) {
        final token = action.wireValue;
        expect(token, isNotEmpty);
        final parsed = AuditAction.tryParse(token);
        expect((parsed as Ok<AuditAction>).value, action);
      }
    });

    test('tokens are the exact ratified set', () {
      expect(AuditAction.values.map((a) => a.wireValue).toSet(), {
        'user_suspended',
        'user_reinstated',
        'participant_ledger_viewed',
        'fixture_result_recorded',
        'round_scored',
        'round_posted_to_ledger',
        'competition_created',
        'season_started',
        'round_opened',
        'round_locked',
        'fixture_linked_to_round',
      });
    });
  });

  group('AuditAction.tryParse', () {
    test('rejects an unknown token as validation', () {
      final result = AuditAction.tryParse('deleted_everything');
      final error = (result as Err<AuditAction>).error;
      expect(error.kind, ErrorKind.validation);
      expect(error.code, 'admin.audit_action_unknown');
    });

    test('rejects null as validation', () {
      final result = AuditAction.tryParse(null);
      expect(
        (result as Err<AuditAction>).error.code,
        'admin.audit_action_unknown',
      );
    });
  });
}
