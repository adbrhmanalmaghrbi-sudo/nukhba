import 'package:shared/shared.dart';

/// Who may discover and join a [Competition].
///
/// Axiom 2 makes private groups first-class from the architectural root, and
/// Axiom 1 makes competition-among-friends the engagement driver; visibility is
/// the seam that lets a competition be either open to the platform or scoped to
/// a private audience. The group-scoping *link* itself arrives with the Groups
/// phase (Roadmap ADR) — here we fix the closed visibility vocabulary so the
/// Competition aggregate can reason about it from day one without a schema
/// change later (expand-only discipline, Platform ADR).
///
/// The set is closed: an unknown value is a validation failure, never coerced.
enum CompetitionVisibility {
  /// Open to the whole platform: any authenticated user may find and join it.
  public,

  /// Restricted to a private audience (e.g. a group). Not discoverable by the
  /// general platform; the audience binding is realized in a later phase.
  private;

  /// The stable wire/storage token for this visibility.
  String get wireValue => switch (this) {
    CompetitionVisibility.public => 'public',
    CompetitionVisibility.private => 'private',
  };

  /// Parses a [CompetitionVisibility] from an untrusted [raw] token, returning a
  /// validation [AppError] when it is absent or unrecognized.
  static Result<CompetitionVisibility> tryParse(String? raw) {
    for (final value in CompetitionVisibility.values) {
      if (value.wireValue == raw) {
        return Result.ok(value);
      }
    }
    return Result.err(
      AppError.validation(
        'competition.visibility_unknown',
        'Unknown competition visibility: ${raw ?? '<null>'}',
      ),
    );
  }
}
