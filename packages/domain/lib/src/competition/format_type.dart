import 'package:shared/shared.dart';

/// The competition's game-format discriminator — the key under which the
/// Game Engine (ADR-001 Tier-2 seam; Application ADR, Section 2.10) is resolved
/// for a round.
///
/// This is a *seam*, not a set of separate tables (Database ADR, Section 3;
/// Next-Task brief): a `Competition` stores its [FormatType], and later phases
/// resolve the matching `GameEngine` implementation from a registry keyed on it.
/// Only [footballScoreline] exists today (Application ADR, Section 2.10: "the
/// ONE impl today"); the enum is the extension point for Survivor/Bracket/etc.
/// without touching Core.
///
/// The set is closed: an unknown value from any external source (path/body,
/// stored row) is a validation failure, never silently coerced (Security ADR,
/// Section 2: untrusted input is validated).
enum FormatType {
  /// Predict the exact scoreline of each fixture in a round — the founding
  /// football format (Axiom 3). Its prediction shape is a home/away score pair;
  /// its scoring lives in the (later-phase) Scoring context, not here
  /// (Application ADR, Section 2.10: the engine defines prediction *shape and
  /// lifecycle*, Scoring defines *how points are earned*).
  footballScoreline;

  /// The stable wire/storage token for this format. Kept explicit (rather than
  /// relying on [name]) so the persisted string is decoupled from the Dart
  /// identifier and can never drift silently.
  String get wireValue => switch (this) {
    FormatType.footballScoreline => 'football_scoreline',
  };

  /// Parses a [FormatType] from an untrusted [raw] token.
  ///
  /// Returns a validation [AppError] rather than throwing, so a malformed or
  /// unrecognized format on a command path (or a corrupt stored row) surfaces as
  /// a typed failure. An absent value is *not* defaulted — a competition must
  /// declare its format explicitly.
  static Result<FormatType> tryParse(String? raw) {
    for (final value in FormatType.values) {
      if (value.wireValue == raw) {
        return Result.ok(value);
      }
    }
    return Result.err(
      AppError.validation(
        'competition.format_type_unknown',
        'Unknown competition format: ${raw ?? '<null>'}',
      ),
    );
  }
}
