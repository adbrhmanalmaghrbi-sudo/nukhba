import 'package:shared/shared.dart';

/// The **closed, fixed set** of emoji a member may react with (Social decision
/// #1: bounded reactions, NO free text — so there is nothing to moderate).
///
/// The domain owns the *set*; the actual emoji glyph rendered to a user is a
/// *client* presentation concern. What travels over the wire and is stored is a
/// stable token ([wireValue]) — exactly as `GroupRole`/`FixtureScoreGrade` carry
/// wire tokens, not presentation. An unknown token from storage or the wire is a
/// validation failure, never silently coerced or stored as arbitrary content.
///
/// The set is deliberately small and expressive enough for the "banter with
/// friends" loop (like / fire / clap / laugh / sad / shock) and closed for v1;
/// extending it is a forward-only schema + enum change, never a free-text field.
enum ReactionKind {
  /// A thumbs-up / like.
  like,

  /// Fire — an impressive result.
  fire,

  /// Applause.
  clap,

  /// Laughing.
  laugh,

  /// Commiseration / sadness.
  sad,

  /// Shock / surprise.
  shock;

  /// The stable wire/storage token for this reaction kind.
  String get wireValue => switch (this) {
    ReactionKind.like => 'like',
    ReactionKind.fire => 'fire',
    ReactionKind.clap => 'clap',
    ReactionKind.laugh => 'laugh',
    ReactionKind.sad => 'sad',
    ReactionKind.shock => 'shock',
  };
}

/// A member's chosen reaction emoji — a value object wrapping the closed
/// [ReactionKind] set (Coding Standards ADR, Section 2: value objects, not
/// primitives).
///
/// Validation lives here so an untrusted emoji token (from a request body or a
/// stored row) is parsed to a member of the closed set before it is ever used —
/// there is no path by which arbitrary text becomes a reaction (Social decision
/// #1). The value carries no points and no open-graph edge (Axiom 5; ADR-001).
final class ReactionEmoji {
  const ReactionEmoji._(this.kind);

  /// The reaction kind (a member of the closed [ReactionKind] set).
  final ReactionKind kind;

  /// The stable wire/storage token (delegates to [ReactionKind.wireValue]).
  String get wireValue => kind.wireValue;

  /// Wraps an already-trusted [kind] (used by the domain when the kind is known
  /// to be valid, e.g. rehydrating from a typed enum).
  const ReactionEmoji.of(this.kind);

  /// Parses a [ReactionEmoji] from an untrusted [raw] token, returning a
  /// validation [AppError] when it is absent or outside the closed set. Kept
  /// total so a reaction attempt with an unsupported emoji fails as a typed
  /// validation error rather than storing arbitrary content.
  static Result<ReactionEmoji> tryParse(String? raw) {
    for (final value in ReactionKind.values) {
      if (value.wireValue == raw) {
        return Result.ok(ReactionEmoji._(value));
      }
    }
    return Result.err(
      AppError.validation(
        'social.reaction_emoji_unknown',
        'Unsupported reaction emoji: ${raw ?? '<null>'}',
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ReactionEmoji && other.kind == kind;

  @override
  int get hashCode => kind.hashCode;

  @override
  String toString() => 'ReactionEmoji(${kind.wireValue})';
}
