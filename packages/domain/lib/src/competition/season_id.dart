import 'package:domain/src/competition/competition_id.dart';
import 'package:shared/shared.dart';

/// The identity of a [CompetitionSeason], a member of the Competition aggregate
/// (Database ADR, Section 3: `Competition` → `CompetitionSeason` → `Round`).
///
/// A value object (Coding Standards ADR, Section 2), canonically a UUID matching
/// the `competition.seasons` primary key. `Participant` is scoped to a
/// [SeasonId] (Database ADR, Section 1: Participant is its own aggregate keyed
/// on the season).
final class SeasonId extends EntityId {
  /// Creates a [SeasonId] from its canonical UUID string.
  const SeasonId(super.value);

  /// Parses a [SeasonId] from an untrusted [raw] string, returning a validation
  /// [AppError] when it is absent or not a canonical UUID.
  static Result<SeasonId> tryParse(String? raw) {
    if (raw == null || raw.isEmpty) {
      return const Result.err(
        AppError.validation(
          'competition.season_id_empty',
          'Season id is required',
        ),
      );
    }
    if (!uuidPattern.hasMatch(raw)) {
      return const Result.err(
        AppError.validation(
          'competition.season_id_malformed',
          'Season id must be a UUID',
        ),
      );
    }
    return Result.ok(SeasonId(raw));
  }
}
