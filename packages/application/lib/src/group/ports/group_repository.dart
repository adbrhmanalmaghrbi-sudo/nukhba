import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// Persistence port for the Groups (Community) context (Application ADR,
/// Section 9: use-cases depend on repository interfaces; Infrastructure
/// implements them).
///
/// Backed by `PostgresGroupRepository`. The interface speaks in domain
/// aggregates and typed ids, never in rows or SQL, so use-cases stay pure and
/// testable against an in-memory fake.
///
/// General contract for every method (Application ADR, Section 2):
/// * MUST NOT throw — every outcome is a typed [Result].
/// * MUST map infrastructure failures to [ErrorKind.transient].
/// * MUST map a domain-integrity conflict it can *only* detect at the storage
///   layer (a uniqueness violation) to [ErrorKind.invariant], so the use-case
///   reports it as a business-rule conflict, not a transient fault
///   (`group.name_taken` for a duplicate name-per-owner is NOT enforced — a
///   duplicate *invite code* is astronomically unlikely and surfaces as
///   `group.invite_code_conflict`; a duplicate `(groupId, userId)` membership
///   surfaces as `group.already_member`, the code `JoinGroupByInvite` pivots on).
abstract interface class GroupRepository {
  /// Persists a newly created [group] together with its owner [ownerMembership]
  /// **atomically** — a group must never exist with no owner row (decision #2).
  /// The ids are caller-generated; a duplicate group id or invite code is an
  /// infrastructure-detected conflict surfaced as [ErrorKind.invariant]
  /// (`group.invite_code_conflict`).
  Future<Result<void>> createGroupWithOwner(
    Group group,
    GroupMembership ownerMembership,
  );

  /// Loads a group by id, or `Ok(null)` when it does not exist. Returning null
  /// (rather than an invariant error) lets the use-case apply the no-existence-
  /// oracle rule uniformly (decision #3): a non-member is refused identically
  /// whether or not the group exists.
  Future<Result<Group?>> findGroup(GroupId id);

  /// Loads a group by its current [inviteCode], or `Ok(null)` when no group has
  /// that code. Used by the join use-case; a stale/rotated code resolves to
  /// null, never to a different group.
  Future<Result<Group?>> findByInviteCode(InviteCode inviteCode);

  /// Persists a lifecycle change (rename or invite regeneration) for an existing
  /// [group], keyed on its id. A rotated invite code that collides with another
  /// group's live code surfaces as [ErrorKind.invariant]
  /// `group.invite_code_conflict`.
  Future<Result<void>> updateGroup(Group group);

  /// Persists a new [membership] (a member joining by invite). The
  /// `(groupId, userId)` pair is unique — a user is in a group at most once — so
  /// a duplicate join surfaces as [ErrorKind.invariant] `group.already_member`.
  Future<Result<void>> saveMembership(GroupMembership membership);

  /// Finds the membership for `(groupId, userId)`, or `Ok(null)` when the user
  /// is not a member. Used to make the join idempotent and to gate member-only
  /// reads (the season-membership-style visibility gate — decision #3).
  Future<Result<GroupMembership?>> findMembership(
    GroupId groupId,
    UserId userId,
  );

  /// Lists all memberships of [groupId] in joinedAt-ascending order (the owner,
  /// who joined first, appears first). An empty list means the group has no
  /// members — which cannot happen for an existing group (the owner is always a
  /// member) but is a legitimate return for an absent group.
  Future<Result<List<GroupMembership>>> listMemberships(GroupId groupId);
}
