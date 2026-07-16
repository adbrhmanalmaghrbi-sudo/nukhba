import 'package:domain/src/competition/competition_id.dart' show uuidPattern;
import 'package:shared/shared.dart';

/// The identity of a [Prediction] aggregate root.
///
/// The `Prediction` aggregate is deliberately **separate** from the Competition
/// aggregate (Database ADR, Section 1 & Section 2.1: high-volume prediction
/// writes must never lock the Competition aggregate — this is the platform's
/// primary scale boundary). Carrying identity as a value object rather than a
/// raw string keeps distinct id types unmixable (Coding Standards ADR,
/// Section 2: value objects, not primitives).
///
/// The canonical form is a UUID, matching the `prediction.predictions` primary
/// key (Database ADR, Section 3). A [PredictionId] is generated server-side at
/// submission time; the client never mints one.
final class PredictionId extends EntityId {
  /// Creates a [PredictionId] from its canonical UUID string.
  ///
  /// Callers that receive untrusted input (e.g. a path parameter) should use
  /// [tryParse], which validates shape and returns a typed [Result] rather than
  /// constructing an id that might be empty or malformed.
  const PredictionId(super.value);

  /// Parses a [PredictionId] from an untrusted [raw] string.
  ///
  /// Returns a validation [AppError] when [raw] is `null`, empty, or not a
  /// canonical (hyphenated, 36-char) UUID. Kept total so no exception escapes
  /// into a command path.
  static Result<PredictionId> tryParse(String? raw) {
    if (raw == null || raw.isEmpty) {
      return const Result.err(
        AppError.validation(
          'prediction.prediction_id_empty',
          'Prediction id is required',
        ),
      );
    }
    if (!uuidPattern.hasMatch(raw)) {
      return const Result.err(
        AppError.validation(
          'prediction.prediction_id_malformed',
          'Prediction id must be a UUID',
        ),
      );
    }
    return Result.ok(PredictionId(raw));
  }
}
