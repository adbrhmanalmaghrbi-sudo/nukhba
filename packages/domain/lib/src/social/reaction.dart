import 'package:domain/src/competition/round_id.dart';
import 'package:domain/src/group/group_id.dart';
import 'package:domain/src/identity/user_id.dart';
import 'package:domain/src/social/reaction_emoji.dart';
import 'package:domain/src/social/reaction_id.dart';
import 'package:shared/shared.dart';

/// A member's emoji reaction to a round-result **within a private group** — the
/// ONE new stored Tier-3 surface this phase introduces (Social decision #2).
///
/// A [Reaction] is **group-scoped** (decision #3: reactions are visible only
/// within the group's membership, reusing the ratified `group.not_a_member`
/// gate) and targets a *round-result* by [roundId] (decision #1: the social
/// surface is round-scored banter, not an open feed of arbitrary objects). The
/// author is a platform [userId]; a member has **at most one live reaction per
/// round-result within a group** — uniqueness of `(groupId, roundId, userId)` is
/// enforced structurally in the schema + the use-case, not re-checked here (an
/// aggregate reasons only about itself; mirror of `GroupMembership`/
/// `Participant`).
///
/// It carries **NO points field** (Axiom 5 — Social is never a second points
/// source) and **NO open-graph edge** (ADR-001 / ADR-006 §2.6 — the only social
/// container is a group). Pure and immutable: state changes produce new values;
/// a member swapping their emoji is an idempotent upsert on the unique key (see
/// [changeEmoji]), never a second row. Value-comparable.
final class Reaction {
  const Reaction._({
    required this.id,
    required this.groupId,
    required this.roundId,
    required this.userId,
    required this.emoji,
    required this.reactedAt,
  });

  /// Rehydrates a [Reaction] from already-trusted stored fields (used by the
  /// infrastructure mapper). Performs no validation beyond typing — callers
  /// creating a *new* reaction from untrusted input must use [create].
  const Reaction.fromStored({
    required this.id,
    required this.groupId,
    required this.roundId,
    required this.userId,
    required this.emoji,
    required this.reactedAt,
  });

  /// Creates a new reaction from validated inputs.
  ///
  /// [id] and [emoji] are already validated value objects (id generated
  /// server-side; emoji parsed from the closed set), so they need no further
  /// checking here. [reactedAt] must be a UTC instant (callers normalize) so
  /// chronological ordering across reactions is unambiguous.
  static Result<Reaction> create({
    required ReactionId id,
    required GroupId groupId,
    required RoundId roundId,
    required UserId userId,
    required ReactionEmoji emoji,
    required DateTime reactedAt,
  }) {
    if (!reactedAt.isUtc) {
      return const Result.err(
        AppError.validation(
          'social.reaction_reacted_at_not_utc',
          'reactedAt must be provided in UTC',
        ),
      );
    }
    return Result.ok(
      Reaction._(
        id: id,
        groupId: groupId,
        roundId: roundId,
        userId: userId,
        emoji: emoji,
        reactedAt: reactedAt,
      ),
    );
  }

  /// The reaction identity.
  final ReactionId id;

  /// The group this reaction is scoped to (the social container — decision #3).
  final GroupId groupId;

  /// The round-result this reaction targets (decision #1).
  final RoundId roundId;

  /// The reacting member's platform user id (bound from the verified token by
  /// the use-case, never a request body — Security ADR §2).
  final UserId userId;

  /// The chosen emoji from the closed set (decision #1).
  final ReactionEmoji emoji;

  /// When the reaction was made or last changed (UTC).
  final DateTime reactedAt;

  /// Returns a copy carrying a new [emoji] and refreshed [reactedAt] (a member
  /// swapping their reaction). The identity + `(groupId, roundId, userId)` key
  /// are unchanged, so persisting this is an idempotent upsert on the unique
  /// key, not a second row. [reactedAt] must be UTC. Authority (the caller must
  /// be the author) is enforced in the use-case, not here.
  Result<Reaction> changeEmoji(ReactionEmoji newEmoji, DateTime reactedAt) {
    if (!reactedAt.isUtc) {
      return const Result.err(
        AppError.validation(
          'social.reaction_reacted_at_not_utc',
          'reactedAt must be provided in UTC',
        ),
      );
    }
    return Result.ok(
      Reaction._(
        id: id,
        groupId: groupId,
        roundId: roundId,
        userId: userId,
        emoji: newEmoji,
        reactedAt: reactedAt,
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Reaction &&
      other.id == id &&
      other.groupId == groupId &&
      other.roundId == roundId &&
      other.userId == userId &&
      other.emoji == emoji &&
      other.reactedAt == reactedAt;

  @override
  int get hashCode =>
      Object.hash(id, groupId, roundId, userId, emoji, reactedAt);

  @override
  String toString() =>
      'Reaction(${id.value}, group: ${groupId.value}, '
      'round: ${roundId.value}, user: ${userId.value}, ${emoji.wireValue})';
}
