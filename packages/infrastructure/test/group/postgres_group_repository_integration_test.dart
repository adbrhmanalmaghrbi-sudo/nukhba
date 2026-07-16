@Tags(['integration'])
library;

import 'package:test/test.dart';

/// DB-gated integration test for [PostgresGroupRepository].
///
/// The behaviours a hermetic unit test cannot cover are the ones that only a
/// real `postgres` server produces:
///
///  1. **Reclassifying a `ServerException` into a domain `invariant`.** The
///     driver's `ServerException` (carrying the SQLSTATE `code` +
///     `constraintName`) has no public constructor, so the adapter's
///     `_reclassify` mapping can only be exercised against real Postgres with
///     the EXPLICITLY-named constraints from `0007_group.sql`:
///       * `groups_invite_code_key` (unique invite code) →
///         `group.invite_code_conflict`
///       * `group_memberships_group_user_uniq` (unique `(group_id, user_id)`) →
///         `group.already_member` (the code `JoinGroupByInvite` pivots on)
///       * `group_memberships_group_id_fkey` (FK → groups) → `group.not_found`
///       * `group_memberships_user_id_fkey` / `groups_owner_id_fkey`
///         (FK → identity.users) → `group.user_not_found`
///  2. **The atomic `createGroupWithOwner` transaction against a live pool** —
///     a group row and its owner-membership row commit together, and a
///     mid-transaction failure (e.g. a duplicate invite code on the group
///     insert) rolls BOTH back, so a group never exists with no owner row
///     (decision #2). Only a real `Pool.runTx` proves the rollback.
///  3. **The reused `leaderboard.season_standings` VIEW intersected with group
///     membership** (`groupSeasonStandings`) — the season-scoped `SUM(amount)`
///     over `ledger.point_entries`, joined to `competition.participants` and
///     filtered to `group.group_memberships`, is a real SQL VIEW that a fake
///     connection cannot execute.
///
/// The VIEW + tables + constraints live in `0001_identity.sql`..`0007_group.sql`,
/// so they can only be exercised against a live schema. This file is tagged
/// `integration` so it is excluded from the hermetic `melos run test` and
/// executed in CI's dedicated integration job against an ephemeral Postgres with
/// migrations 0001–0007 applied (see ci.yaml), matching the existing
/// leaderboard + ledger + scoring + prediction + competition + health harness.
///
/// The scenarios CI must exercise once wired end-to-end (each asserts the exact
/// shape the use-case + hermetic unit tests expect):
///
/// createGroupWithOwner / findGroup / findByInviteCode:
///   * happy path — a created group is readable by id and by its current invite
///     code; the owner membership is present with `GroupRole.owner`
///   * **atomic rollback** — inserting a group whose invite code collides with
///     an existing group's live code fails with `group.invite_code_conflict`
///     AND leaves NO orphan group / membership row (the whole tx rolled back)
///   * a rotated (stale) invite code resolves to `Ok(null)` via
///     `findByInviteCode`, never to a different group
///
/// saveMembership / findMembership / listMemberships:
///   * a second user joining resolves to a `member` membership; `findMembership`
///     returns it, `listMemberships` returns owner-then-member in joined_at ASC
///   * a duplicate `(group_id, user_id)` join surfaces `group.already_member`
///     (the pivot for idempotent join), never a second row
///   * a membership insert for a non-existent group surfaces `group.not_found`;
///     for a non-existent user surfaces `group.user_not_found`
///
/// updateGroup:
///   * a rename persists; an invite regeneration persists and the OLD code no
///     longer resolves while the NEW one does
///   * a regenerated code that collides with another group's live code surfaces
///     `group.invite_code_conflict` and leaves the row unchanged
///
/// groupSeasonStandings (reused season_standings VIEW ∩ membership):
///   * happy path — a group whose members are also season participants returns
///     one entry per (member ∩ participant), `totalPoints` equal to that
///     participant's season ledger `SUM(amount)` (nets in corrections — Axiom 5)
///   * **membership filter** — a season participant who is NOT a group member is
///     EXCLUDED; a group member who is NOT a season participant is EXCLUDED
///     (only the intersection appears)
///   * **enrolled-but-never-credited** — a member∩participant with no ledger
///     entries still appears with `totalPoints == 0`, `entryCount == 0`
///   * **season scoping** — entries from a different season are not summed
///   * `joined_at` returned as UTC so the domain tie-break (joinedAt ASC) is
///     unambiguous
///   * an empty intersection yields an empty list (a legitimate empty board)
void main() {
  test(
    'group tables + season_standings∩membership VIEW behave against a live DB',
    () {
      // Wired in CI's integration job against an ephemeral Postgres service
      // with `supabase/migrations/0001_identity.sql` through
      // `0007_group.sql` applied. Skipped locally so `melos run test` stays
      // hermetic.
    },
    skip: 'Runs only in the CI integration job with a live Postgres service.',
  );
}
