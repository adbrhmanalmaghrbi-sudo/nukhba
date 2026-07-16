import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

void main() {
  group('ReactionId', () {
    const validUuid = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890';

    test('tryParse accepts a canonical UUID', () {
      final parsed = ReactionId.tryParse(validUuid);
      expect(parsed, isA<Ok<ReactionId>>());
      expect((parsed as Ok<ReactionId>).value.value, validUuid);
    });

    test('tryParse rejects null/empty as validation', () {
      expect(
        (ReactionId.tryParse(null) as Err<ReactionId>).error.code,
        'social.reaction_id_empty',
      );
      expect(
        (ReactionId.tryParse('') as Err<ReactionId>).error.code,
        'social.reaction_id_empty',
      );
    });

    test('tryParse rejects a malformed id as validation', () {
      final bad = ReactionId.tryParse('not-a-uuid');
      expect((bad as Err<ReactionId>).error.kind, ErrorKind.validation);
      expect(bad.error.code, 'social.reaction_id_malformed');
    });

    test(
      'is a distinct id type (never equal to another EntityId of same value)',
      () {
        expect(
          const ReactionId(validUuid) == const GroupId(validUuid),
          isFalse,
        );
        expect(const ReactionId(validUuid), const ReactionId(validUuid));
      },
    );
  });
}
