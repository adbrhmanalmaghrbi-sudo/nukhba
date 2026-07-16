import 'package:domain/src/competition/competition_id.dart';
import 'package:domain/src/competition/season_id.dart';
import 'package:shared/shared.dart';

/// A season of a [Competition] (Database ADR, Section 3: `Competition` →
/// `CompetitionSeason` → `Round`; a season belongs to exactly one competition).
///
/// A season is the scope a `Participant` joins (Database ADR, Section 1:
/// Participant is keyed on the season) and the partition key for the large
/// tables (predictions, ledger — Database ADR, Section: "partitionable by
/// season"). It carries a human [label] (e.g. "2026/27") for display.
///
/// Pure and immutable; value-comparable.
final class CompetitionSeason {
  const CompetitionSeason._({
    required this.id,
    required this.competitionId,
    required this.label,
  });

  /// Rehydrates a season from already-trusted stored fields (infrastructure
  /// mapper). No validation beyond typing.
  const CompetitionSeason.fromStored({
    required this.id,
    required this.competitionId,
    required this.label,
  });

  /// Creates a new season from validated inputs. [label] is trimmed and
  /// length-checked (1–60 chars) so an empty or oversized label is rejected.
  static Result<CompetitionSeason> create({
    required SeasonId id,
    required CompetitionId competitionId,
    required String label,
  }) {
    final trimmed = label.trim();
    if (trimmed.isEmpty) {
      return const Result.err(
        AppError.validation(
          'competition.season_label_empty',
          'Season label is required',
        ),
      );
    }
    if (trimmed.length > _maxLabelLength) {
      return const Result.err(
        AppError.validation(
          'competition.season_label_too_long',
          'Season label must be at most $_maxLabelLength characters',
        ),
      );
    }
    return Result.ok(
      CompetitionSeason._(id: id, competitionId: competitionId, label: trimmed),
    );
  }

  static const int _maxLabelLength = 60;

  /// The season identity.
  final SeasonId id;

  /// The owning competition. A season belongs to exactly one competition
  /// (Database ADR, Section 3).
  final CompetitionId competitionId;

  /// The display label for the season (trimmed, 1–60 chars).
  final String label;

  @override
  bool operator ==(Object other) =>
      other is CompetitionSeason &&
      other.id == id &&
      other.competitionId == competitionId &&
      other.label == label;

  @override
  int get hashCode => Object.hash(id, competitionId, label);

  @override
  String toString() =>
      'CompetitionSeason(${id.value}, competition: ${competitionId.value}, '
      '"$label")';
}
