import 'package:shared/shared.dart';
import 'package:test/test.dart';

void main() {
  group('Result', () {
    test('Ok carries value and reports isOk', () {
      const result = Result<int>.ok(42);
      expect(result.isOk, isTrue);
      expect(result.isErr, isFalse);
      expect((result as Ok<int>).value, 42);
    });

    test('Err carries error and reports isErr', () {
      const error = AppError.transient('x', 'boom');
      const result = Result<int>.err(error);
      expect(result.isErr, isTrue);
      expect((result as Err<int>).error, error);
    });

    test('map transforms Ok and preserves Err', () {
      const ok = Result<int>.ok(2);
      expect((ok.map((v) => v * 10) as Ok<int>).value, 20);

      const err = Result<int>.err(AppError.validation('c', 'm'));
      expect(err.map((v) => v * 10).isErr, isTrue);
    });

    test('getOrElse returns value on Ok and fallback on Err', () {
      const ok = Result<int>.ok(5);
      expect(ok.getOrElse((_) => -1), 5);

      const err = Result<int>.err(AppError.transient('c', 'm'));
      expect(err.getOrElse((_) => -1), -1);
    });

    test('AppError.isRetryable is true only for transient', () {
      expect(const AppError.transient('c', 'm').isRetryable, isTrue);
      expect(const AppError.invariant('c', 'm').isRetryable, isFalse);
      expect(const AppError.authorization('c', 'm').isRetryable, isFalse);
      expect(const AppError.validation('c', 'm').isRetryable, isFalse);
    });
  });
}
