import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

const _uuid = '11111111-1111-1111-1111-111111111111';

void main() {
  group('PredictionId.tryParse', () {
    test('accepts a canonical UUID', () {
      final result = PredictionId.tryParse(_uuid);
      expect((result as Ok<PredictionId>).value, const PredictionId(_uuid));
    });

    test('rejects null', () {
      final result = PredictionId.tryParse(null);
      final error = (result as Err<PredictionId>).error;
      expect(error.kind, ErrorKind.validation);
      expect(error.code, 'prediction.prediction_id_empty');
    });

    test('rejects an empty string', () {
      final result = PredictionId.tryParse('');
      final error = (result as Err<PredictionId>).error;
      expect(error.kind, ErrorKind.validation);
      expect(error.code, 'prediction.prediction_id_empty');
    });

    test('rejects a non-UUID string', () {
      final result = PredictionId.tryParse('not-a-uuid');
      final error = (result as Err<PredictionId>).error;
      expect(error.kind, ErrorKind.validation);
      expect(error.code, 'prediction.prediction_id_malformed');
    });
  });

  group('PredictionId identity', () {
    test('is an EntityId carrying its canonical value', () {
      const id = PredictionId(_uuid);
      expect(id, isA<EntityId>());
      expect(id.value, _uuid);
    });

    test('two ids with the same value compare equal', () {
      expect(const PredictionId(_uuid), const PredictionId(_uuid));
      expect(
        const PredictionId(_uuid).hashCode,
        const PredictionId(_uuid).hashCode,
      );
    });
  });
}
