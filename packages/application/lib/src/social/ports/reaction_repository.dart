import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// Persistence port for the Social Reactions surface — the ONE new stored
/// Tier-3 aggregate (Social decision #2; Application ADR §9: use-cases depend on
/// repository interfaces, Infrastructure implements them).
///
/// Backed by `PostgresReactionRepository`. The interface speaks in the domain
/// [Reaction] aggregate and typed ids, never rows or SQL, so use-cases stay pure
/// and testable against an in-memory fake.
///
/// General contract for every method (Application ADR §2):
/// * MUST NOT throw — every outcome is a typed [Result].
/// * MUST map infrastructure failures to [ErrorKind.transient].
/// * MUST map a storage-only uniqueness conflict to [ErrorKind.invariant] so
///   the use-case reports it as a business conflict — a duplicate
///   `(groupId, roundId, userId)` surfaces as `social.reaction_conflict`, which
///   the idempotent upsert converges on rather than erroring.
///
/// **Tier-3 degradation (decision #4):** a failure here is a typed
/// `Result.err` confined to the Social use-case that called it; it never
/// propagates into a Tier-1 core operation (prediction/scoring/ledger/
/// leaderboard), which do not depend on this port.
abstract interface class ReactionRepository {
  /// Persists a member's [reaction] **idempotently** on the natural key
  /// `(groupId, roundId, userId)`: a first reaction inserts; a member changing
  /// their emoji updates the existing row in place (never a second row —
  /// decision #1/#2). The caller-generated [Reaction.id] is used only on the
  /// initial insert; a subsequent change keeps the stored id. A genuine racing
  /// duplicate that the DB rejects surfaces as [ErrorKind.invariant]
  /// `social.reaction_conflict`, which the use-case resolves by re-reading.
  Future<Result<void>> upsertReaction(Reaction reaction);

  /// Finds the caller's reaction for `(groupId, roundId, userId)`, or
  /// `Ok(null)` when the member has not reacted. Used to make the react/remove
  /// use-cases idempotent.
  Future<Result<Reaction?>> findReaction(
    GroupId groupId,
    RoundId roundId,
    UserId userId,
  );

  /// Lists all reactions to `(groupId, roundId)` in reactedAt-ascending order.
  /// An empty list means no member has reacted yet (a legitimate result).
  Future<Result<List<Reaction>>> listReactionsForRound(
    GroupId groupId,
    RoundId roundId,
  );

  /// Removes the caller's reaction for `(groupId, roundId, userId)`, if any.
  /// Idempotent: removing an absent reaction is a no-op success (`Ok`), so a
  /// retried remove converges. Returns `Ok(true)` when a row was removed,
  /// `Ok(false)` when there was nothing to remove.
  Future<Result<bool>> removeReaction(
    GroupId groupId,
    RoundId roundId,
    UserId userId,
  );
}
