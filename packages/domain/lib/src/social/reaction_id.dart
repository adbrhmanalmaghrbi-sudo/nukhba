import 'package:shared/shared.dart';

/// The identity of a [Reaction] aggregate root — a member's emoji reaction to a
/// round-result within a private group (Social phase; Database ADR 0003 §3:
/// Social is a Tier-3 peripheral aggregate, group-scoped).
///
/// A value object (Coding Standards ADR, Section 2), canonically a UUID matching
/// the `social.reactions` primary key. Kept a distinct id type from
/// `GroupId`/`RoundId`/`UserId` so a reaction row is never addressed by a group,
/// round, or user id by mistake.
final class ReactionId extends EntityId {
  /// Creates a [ReactionId] from its canonical UUID string.
  ///
  /// Callers that receive untrusted input should use [tryParse], which validates
  /// shape and returns a typed [Result] rather than constructing an id that
  /// might be empty or malformed.
  const ReactionId(super.value);

  /// Parses a [ReactionId] from an untrusted [raw] string, returning a
  /// validation [AppError] when it is absent or not a canonical (hyphenated,
  /// 36-char) UUID.
  static Result<ReactionId> tryParse(String? raw) {
    if (raw == null || raw.isEmpty) {
      return const Result.err(
        AppError.validation(
          'social.reaction_id_empty',
          'Reaction id is required',
        ),
      );
    }
    if (!_uuid.hasMatch(raw)) {
      return const Result.err(
        AppError.validation(
          'social.reaction_id_malformed',
          'Reaction id must be a UUID',
        ),
      );
    }
    return Result.ok(ReactionId(raw));
  }

  /// Canonical UUID form: 8-4-4-4-12 hexadecimal, case-insensitive.
  static final RegExp _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
    r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );
}
