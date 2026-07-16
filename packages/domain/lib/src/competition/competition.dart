import 'package:domain/src/competition/competition_id.dart';
import 'package:domain/src/competition/competition_visibility.dart';
import 'package:domain/src/competition/format_type.dart';
import 'package:shared/shared.dart';

/// The Competition aggregate root (Database ADR, Section 3: root `Competition` →
/// `CompetitionSeason` → `Round`).
///
/// A competition is a long-lived container: it declares *what game is played*
/// ([format], the Game-Engine seam key — Application ADR, Section 2.10) and
/// *who may join* ([visibility]), then hosts one or more seasons over time. It
/// holds no scoring math (that is the Scoring context) and no point balances
/// (that is Ledger) — those are later phases; Competition only owns structure
/// (Next-Task brief).
///
/// Pure and immutable: no framework, no IO. State changes produce new values via
/// [copyWith]; the entity is value-comparable.
final class Competition {
  const Competition._({
    required this.id,
    required this.name,
    required this.format,
    required this.visibility,
  });

  /// Rehydrates a [Competition] from already-trusted stored fields (used by the
  /// infrastructure mapper). Performs no validation beyond typing — callers
  /// creating a *new* competition from untrusted input must use [create].
  const Competition.fromStored({
    required this.id,
    required this.name,
    required this.format,
    required this.visibility,
  });

  /// Creates a new competition from validated inputs.
  ///
  /// [name] is trimmed and length-checked (1–120 chars after trimming) so an
  /// empty or oversized name is rejected as a validation failure rather than
  /// persisted. [format] and [visibility] are already closed domain enums, so
  /// they need no further checking here.
  static Result<Competition> create({
    required CompetitionId id,
    required String name,
    required FormatType format,
    required CompetitionVisibility visibility,
  }) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      return const Result.err(
        AppError.validation(
          'competition.name_empty',
          'Competition name is required',
        ),
      );
    }
    if (trimmed.length > _maxNameLength) {
      return const Result.err(
        AppError.validation(
          'competition.name_too_long',
          'Competition name must be at most $_maxNameLength characters',
        ),
      );
    }
    return Result.ok(
      Competition._(
        id: id,
        name: trimmed,
        format: format,
        visibility: visibility,
      ),
    );
  }

  static const int _maxNameLength = 120;

  /// The aggregate identity.
  final CompetitionId id;

  /// The display name (trimmed, 1–120 chars).
  final String name;

  /// The game-format discriminator; resolves the Game Engine for the
  /// competition's rounds (Application ADR, Section 2.10). Fixed for the life of
  /// the competition — changing the game a competition plays is a new
  /// competition, not a mutation.
  final FormatType format;

  /// Who may discover and join this competition.
  final CompetitionVisibility visibility;

  /// Returns a copy with [visibility] replaced. [format] is intentionally not
  /// copyable — a competition's game type is immutable by design.
  Competition copyWith({CompetitionVisibility? visibility}) {
    return Competition._(
      id: id,
      name: name,
      format: format,
      visibility: visibility ?? this.visibility,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Competition &&
      other.id == id &&
      other.name == name &&
      other.format == format &&
      other.visibility == visibility;

  @override
  int get hashCode => Object.hash(id, name, format, visibility);

  @override
  String toString() =>
      'Competition(${id.value}, "$name", ${format.wireValue}, '
      '${visibility.wireValue})';
}
