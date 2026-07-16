import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

void main() {
  group('InviteCode.tryParse', () {
    test('accepts a well-formed code from the alphabet', () {
      final result = InviteCode.tryParse('ABCDEFGHJK');
      expect(result, isA<Ok<InviteCode>>());
      expect((result as Ok<InviteCode>).value.value, 'ABCDEFGHJK');
    });

    test('rejects null/empty as validation', () {
      expect(
        (InviteCode.tryParse(null) as Err<InviteCode>).error.code,
        'group.invite_code_empty',
      );
      expect(
        (InviteCode.tryParse('') as Err<InviteCode>).error.code,
        'group.invite_code_empty',
      );
    });

    test('rejects a wrong-length code as validation', () {
      final short = InviteCode.tryParse('ABC');
      expect((short as Err<InviteCode>).error.kind, ErrorKind.validation);
      expect(short.error.code, 'group.invite_code_malformed');
      expect(
        (InviteCode.tryParse('ABCDEFGHJKX') as Err<InviteCode>).error.code,
        'group.invite_code_malformed',
      );
    });

    test('rejects a character outside the closed alphabet', () {
      // Contains ambiguous excluded chars: 0, O, 1, I, L, and lower-case.
      for (final bad in <String>[
        'ABCDEFGHJ0',
        'ABCDEFGHJO',
        'ABCDEFGHJ1',
        'ABCDEFGHJI',
        'ABCDEFGHJL',
        'abcdefghjk',
        'ABCDEFGHJ-',
      ]) {
        final result = InviteCode.tryParse(bad);
        expect(
          (result as Err<InviteCode>).error.code,
          'group.invite_code_malformed',
          reason: 'expected $bad to be rejected',
        );
      }
    });

    test('alphabet excludes ambiguous characters', () {
      for (final ambiguous in <String>['0', 'O', '1', 'I', 'L']) {
        expect(InviteCode.isAllowedChar(ambiguous), isFalse);
      }
      expect(InviteCode.alphabet.length, greaterThan(20));
      expect(InviteCode.codeLength, 10);
    });

    test('value equality holds', () {
      final a = (InviteCode.tryParse('ABCDEFGHJK') as Ok<InviteCode>).value;
      final b = (InviteCode.tryParse('ABCDEFGHJK') as Ok<InviteCode>).value;
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });
}
