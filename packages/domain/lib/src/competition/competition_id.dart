import 'package:shared/shared.dart';

/// The identity of a [Competition] aggregate root, carried as a value object
/// rather than a raw string so distinct id types cannot be mixed (Coding
/// Standards ADR, Section 2: value objects, not primitives).
///
/// The canonical form is a UUID, matching the `competition.competitions`
/// primary key (Database ADR, Section 3: `Competition` is the Competition
/// aggregate root).
final class CompetitionId extends EntityId {
  /// Creates a [CompetitionId] from its canonical UUID string.
  ///
  /// Callers that receive untrusted input (e.g. a path parameter) should use
  /// [tryParse], which validates shape and returns a typed [Result] rather than
  /// constructing an id that might be empty or malformed.
  const CompetitionId(super.value);

  /// Parses a [CompetitionId] from an untrusted [raw] string.
  ///
  /// Returns a validation [AppError] when [raw] is `null`, empty, or not a
  /// canonical (hyphenated, 36-char) UUID. Kept total so no exception escapes
  /// into a command path.
  static Result<CompetitionId> tryParse(String? raw) {
    if (raw == null || raw.isEmpty) {
      return const Result.err(
        AppError.validation(
          'competition.competition_id_empty',
          'Competition id is required',
        ),
      );
    }
    if (!uuidPattern.hasMatch(raw)) {
      return const Result.err(
        AppError.validation(
          'competition.competition_id_malformed',
          'Competition id must be a UUID',
        ),
      );
    }
    return Result.ok(CompetitionId(raw));
  }
}

/// Canonical UUID form used across the Competition aggregate ids: 8-4-4-4-12
/// hexadecimal, case-insensitive. Shared so every id type validates identically
/// and the regexp is compiled once.
final RegExp uuidPattern = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
  r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);
