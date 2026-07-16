import 'package:application/src/common/clock.dart';
import 'package:application/src/common/id_generator.dart';
import 'package:application/src/group/ports/group_repository.dart';
import 'package:application/src/identity/authorization.dart';
import 'package:application/src/social/ports/reaction_repository.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// Command use-case: a group member reacts to a round-result with an emoji, or
/// changes an existing reaction (Application ADR §2: command intent
/// `ReactToRound`).
///
/// *Any* authenticated user may react (Axiom 1, social-first), but only as a
/// **member** of the group the reaction is scoped to — the exact ratified
/// `group.not_a_member` gate (Groups decision #3), reused via
/// [GroupRepository.findMembership], with NO existence oracle (a non-member is
/// refused identically whether or not the group/round exists). The author is
/// taken from the verified token, never the body (Security ADR §2), so a caller
/// can never react as someone else.
///
/// Idempotent (Application ADR §2; decision #2): a member reacting again — with
/// the same or a different emoji — updates their single reaction in place rather
/// than creating a second row (uniqueness `(groupId, roundId, userId)`). A lost
/// concurrent-react race that the storage layer rejects
/// (`social.reaction_conflict`) is resolved by re-reading and re-applying, so
/// the caller still gets a successful result.
///
/// **Tier-3 (decision #4):** this is a Social write; a failure is confined to
/// this use-case and never blocks a Tier-1 core operation.
///
/// Never throws; returns a typed [Result] carrying the resulting [Reaction].
final class ReactToRound {
  /// Creates the use-case over its collaborators.
  const ReactToRound({
    required ReactionRepository reactions,
    required GroupRepository groups,
    required IdGenerator idGenerator,
    required Clock clock,
  }) : _reactions = reactions,
       _groups = groups,
       _idGenerator = idGenerator,
       _clock = clock;

  final ReactionRepository _reactions;
  final GroupRepository _groups;
  final IdGenerator _idGenerator;
  final Clock _clock;

  /// Records [principal]'s [emoji] reaction to `(groupId, roundId)`.
  Future<Result<Reaction>> call({
    required AuthenticatedUser principal,
    required String groupId,
    required String roundId,
    required String emoji,
  }) async {
    // Layer 1: platform authority — any signed-in user.
    final auth = Authorization.requireRole(principal, PlatformRole.user);
    if (auth is Err<AuthenticatedUser>) {
      return Result.err(auth.error);
    }

    final gIdResult = GroupId.tryParse(groupId);
    if (gIdResult is Err<GroupId>) {
      return Result.err(gIdResult.error);
    }
    final gId = (gIdResult as Ok<GroupId>).value;

    final rIdResult = RoundId.tryParse(roundId);
    if (rIdResult is Err<RoundId>) {
      return Result.err(rIdResult.error);
    }
    final rId = (rIdResult as Ok<RoundId>).value;

    final emojiResult = ReactionEmoji.tryParse(emoji);
    if (emojiResult is Err<ReactionEmoji>) {
      return Result.err(emojiResult.error);
    }
    final chosen = (emojiResult as Ok<ReactionEmoji>).value;

    // Layer 2 (visibility): the caller must be a member of the group. Refused
    // identically whether or not the group exists (no existence oracle —
    // decision #3, mirror of `ListGroupMembers`/`GetGroupLeaderboard`).
    final gate = await _requireMember(gId, principal.userId);
    if (gate is Err<void>) {
      return Result.err(gate.error);
    }

    // Idempotency: if the member already has a reaction, change it in place
    // (preserving the stored id + key), else create a new one.
    final existingResult = await _reactions.findReaction(
      gId,
      rId,
      principal.userId,
    );
    if (existingResult is Err<Reaction?>) {
      return Result.err(existingResult.error);
    }
    final existing = (existingResult as Ok<Reaction?>).value;

    final now = _clock.nowUtc();
    final Result<Reaction> built;
    if (existing != null) {
      built = existing.changeEmoji(chosen, now);
    } else {
      final idResult = ReactionId.tryParse(_idGenerator.newUuid());
      if (idResult is Err<ReactionId>) {
        return Result.err(idResult.error);
      }
      built = Reaction.create(
        id: (idResult as Ok<ReactionId>).value,
        groupId: gId,
        roundId: rId,
        userId: principal.userId,
        emoji: chosen,
        reactedAt: now,
      );
    }
    if (built is Err<Reaction>) {
      return Result.err(built.error);
    }
    final reaction = (built as Ok<Reaction>).value;

    final saved = await _reactions.upsertReaction(reaction);
    return switch (saved) {
      Ok<void>() => Result.ok(reaction),
      Err<void>(:final error) => await _resolveConflict(
        error,
        gId,
        rId,
        principal.userId,
        chosen,
      ),
    };
  }

  /// Reuses the ratified member-scoped visibility gate. A non-member (or an
  /// absent group) is refused `group.not_a_member` — no existence oracle.
  Future<Result<void>> _requireMember(GroupId groupId, UserId userId) async {
    final membershipResult = await _groups.findMembership(groupId, userId);
    if (membershipResult is Err<GroupMembership?>) {
      return Result.err(membershipResult.error);
    }
    final membership = (membershipResult as Ok<GroupMembership?>).value;
    if (membership == null) {
      return Result.err(
        const AppError.authorization(
          'group.not_a_member',
          'Only a member of the group may react in it',
        ),
      );
    }
    return const Result.ok(null);
  }

  /// On a unique-violation conflict from a concurrent react, re-read the winning
  /// reaction and re-apply the caller's chosen emoji so the result is still a
  /// successful, idempotent upsert. Any other error is propagated unchanged.
  Future<Result<Reaction>> _resolveConflict(
    AppError error,
    GroupId groupId,
    RoundId roundId,
    UserId userId,
    ReactionEmoji chosen,
  ) async {
    if (error.code != 'social.reaction_conflict') {
      return Result.err(error);
    }
    final reread = await _reactions.findReaction(groupId, roundId, userId);
    if (reread is Err<Reaction?>) {
      return Result.err(reread.error);
    }
    final winning = (reread as Ok<Reaction?>).value;
    if (winning == null) {
      return Result.err(error);
    }
    // Re-apply the caller's intended emoji on top of the winning row (in place).
    final updated = winning.changeEmoji(chosen, _clock.nowUtc());
    if (updated is Err<Reaction>) {
      return Result.err(updated.error);
    }
    final reaction = (updated as Ok<Reaction>).value;
    final resaved = await _reactions.upsertReaction(reaction);
    return switch (resaved) {
      Ok<void>() => Result.ok(reaction),
      Err<void>(:final error) => Result.err(error),
    };
  }
}
