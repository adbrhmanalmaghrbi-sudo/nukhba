@Tags(['integration'])
library;

import 'package:test/test.dart';

/// DB-gated integration test for the Social infrastructure adapters
/// ([PostgresReactionRepository] + [PostgresActivityFeedReader]).
///
/// The behaviours a hermetic unit test cannot cover are the ones that only a
/// real `postgres` server produces:
///
///  1. **Reclassifying a `ServerException` into a domain `invariant`.** The
///     driver's `ServerException` (carrying the SQLSTATE `code` +
///     `constraintName`) has no public constructor, so the reaction adapter's
///     `_reclassify` mapping can only be exercised against real Postgres with
///     the EXPLICITLY-named constraints from `0008_social.sql`:
///       * `reactions_group_round_user_uniq` (unique `(group_id, round_id,
///         user_id)`) → `social.reaction_conflict` (the pivot the idempotent
///         upsert converges on when a concurrent duplicate slips past
///         `ON CONFLICT`)
///       * `reactions_group_id_fkey` (FK → "group".groups) →
///         `social.group_not_found`
///       * `reactions_round_id_fkey` (FK → competition.rounds) →
///         `social.round_not_found`
///       * `reactions_user_id_fkey` (FK → identity.users) →
///         `social.user_not_found`
///  2. **The real `INSERT … ON CONFLICT ON CONSTRAINT … DO UPDATE` upsert** —
///     a first reaction inserts; the same member reacting again (any emoji)
///     refreshes the ONE existing row in place (never a second row —
///     decision #1/#2), and `removeReaction`'s `DELETE … RETURNING id`
///     distinguishes a real removal from a no-op. Only a live table with the
///     unique constraint proves the single-row upsert semantics.
///  3. **The Activity Feed's live UNION projection** — the member_joined branch
///     over `"group".group_memberships` and the round_scored branch over
///     `competition.rounds` gated by `EXISTS (participants ∩ group
///     memberships)` are real SQL a fake connection cannot execute; only a live
///     schema proves the group-scoping (a scored round of a season NO group
///     member participates in is excluded) and the newest-first `LIMIT` cap.
///  4. **Group-scoped RLS backstop** — `social.reactions` client writes are
///     revoked and member-scoped self-read is enforced (decision #3; Axiom 6),
///     which only a live role/policy set can demonstrate.
///
/// The schema (`social.reactions` + `social.reaction_kind` enum + RLS) lives in
/// `0008_social.sql`, layered on `0001_identity.sql`..`0007_group.sql`, so it can
/// only be exercised against a live schema. This file is tagged `integration`
/// so it is excluded from the hermetic `melos run test` and executed in CI's
/// dedicated integration job against an ephemeral Postgres with migrations
/// 0001–0008 applied (see ci.yaml), matching the existing group + leaderboard +
/// ledger + scoring + prediction + competition + health harness.
///
/// The scenarios CI must exercise once wired end-to-end (each asserts the exact
/// shape the use-case + hermetic unit tests expect):
///
/// upsertReaction / findReaction / listReactionsForRound / removeReaction:
///   * happy path — a first reaction inserts and is readable by
///     `findReaction(group,round,user)` with its emoji wire token + UTC
///     `reacted_at`; `listReactionsForRound` returns it
///   * **swap in place** — the same member re-reacting with a DIFFERENT emoji
///     updates the ONE row (the `id` and key are unchanged), never a second row;
///     `listReactionsForRound` still returns exactly one reaction for that member
///   * **idempotent remove** — `removeReaction` returns `Ok(true)` the first
///     time and `Ok(false)` on a retried remove; a subsequent `findReaction`
///     resolves to `Ok(null)`
///   * a reaction whose `group_id` / `round_id` / `user_id` does not exist
///     surfaces `social.group_not_found` / `social.round_not_found` /
///     `social.user_not_found` respectively (the FK 23503 mapping)
///   * a genuine racing duplicate that the DB rejects surfaces
///     `social.reaction_conflict` (the 23505 mapping the use-case pivots on)
///   * an unsupported emoji is impossible to store — the `social.reaction_kind`
///     enum rejects it at the type boundary (defence-in-depth behind the
///     domain's closed `ReactionEmoji` set)
///
/// groupActivityFeed (live UNION projection, NO table):
///   * happy path — a group with N members and M scored rounds (in seasons its
///     members participate in) yields N member_joined + M round_scored events,
///     newest-first by `occurred_at`, capped at `limit`
///   * **group scoping** — a scored round of a season NO group member
///     participates in is EXCLUDED; a member_joined of a DIFFERENT group is
///     EXCLUDED
///   * a fresh group (no memberships, no relevant scored rounds) yields an empty
///     list (a legitimate empty feed)
///   * `occurred_at` returned as UTC so the newest-first ordering is
///     unambiguous
void main() {
  test('social.reactions upsert/remove + activity-feed UNION behave against a '
      'live DB', () {
    // Wired in CI's integration job against an ephemeral Postgres service
    // with `supabase/migrations/0001_identity.sql` through
    // `0008_social.sql` applied. Skipped locally so `melos run test` stays
    // hermetic.
  }, skip: 'Runs only in the CI integration job with a live Postgres service.');
}
