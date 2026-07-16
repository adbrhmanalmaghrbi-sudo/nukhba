import 'package:domain/src/competition/competition_id.dart';
import 'package:shared/shared.dart';

/// The identity of a [Round], a member of the Competition aggregate
/// (Database ADR, Section 3: a round belongs to exactly one season).
///
/// A value object (Coding Standards ADR, Section 2), canonically a UUID matching
/// the `competition.rounds` primary key. A `RoundFixture` link references a
/// [RoundId]; a later-phase `Prediction` references exactly one `RoundFixture`.
final class RoundId extends EntityId {
  /// Creates a [RoundId] from its canonical UUID string.
  const RoundId(super.value);

  /// Parses a [RoundId] from an untrusted [raw] string, returning a validation
  /// [AppError] when it is absent or not a canonical UUID.
  static Result<RoundId> tryParse(String? raw) {
    if (raw == null || raw.isEmpty) {
      return const Result.err(
        AppError.validation(
          'competition.round_id_empty',
          'Round id is required',
        ),
      );
    }
    if (!uuidPattern.hasMatch(raw)) {
      return const Result.err(
        AppError.validation(
          'competition.round_id_malformed',
          'Round id must be a UUID',
        ),
      );
    }
    return Result.ok(RoundId(raw));
  }
}
