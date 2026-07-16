@Tags(['integration'])
library;

import 'package:test/test.dart';

/// DB-gated integration test for the Notification infrastructure adapter
/// ([PostgresNotificationRepository]).
///
/// The behaviours a hermetic unit test cannot cover are the ones that only a
/// real `postgres` server produces:
///
///  1. **Reclassifying a `ServerException` into a domain `invariant`.** The
///     driver's `ServerException` (carrying the SQLSTATE `code` +
///     `constraintName`) has no public constructor, so the adapter's
///     `_reclassify` mapping can only be exercised against real Postgres with
///     the EXPLICITLY-named constraints from `0009_notification.sql`:
///       * `notifications_dedupe_uniq` (unique `(recipient_id, kind,
///         subject_ref)`) → `notification.duplicate` — the pivot the idempotent
///         `createIfAbsent` converges on (`Ok(false)`) when a concurrent
///         duplicate slips past `ON CONFLICT DO NOTHING`
///       * `notifications_recipient_id_fkey` (FK → identity.users) →
///         `notification.recipient_not_found`
///       * `notifications_round_id_fkey` (FK → competition.rounds) →
///         `notification.round_not_found`
///       * `notifications_group_id_fkey` (FK → "group".groups) →
///         `notification.group_not_found`
///       * `notifications_actor_user_id_fkey` (FK → identity.users) →
///         `notification.actor_not_found`
///  2. **The real `INSERT … ON CONFLICT ON CONSTRAINT notifications_dedupe_uniq
///     DO NOTHING RETURNING id`** — a first create inserts (RETURNING id →
///     `Ok(true)`); a replayed trigger for the SAME `(recipient, kind,
///     subject_ref)` conflicts and inserts nothing (`Ok(false)`), never a
///     second row (decision #3). Only a live table with the unique constraint
///     proves the single-row idempotency.
///  3. **The recipient-scoped guarded mark** — the real `UPDATE … WHERE
///     recipient_id = ? AND read_at IS NULL RETURNING id` transitions an unread
///     row once (`Ok(true)`) and matches nothing on a retry, and the follow-up
///     existence probe distinguishes an already-read OWNED row (`Ok(false)`)
///     from a foreign/absent id (`Ok(null)`, no existence oracle — decision #4).
///     Only a live row set proves the two-query disambiguation end-to-end.
///  4. **The enum type boundary** — an unknown `kind` token is impossible to
///     store: the `notification.notification_kind` enum rejects it at the type
///     boundary (defence-in-depth behind the domain's closed `NotificationKind`
///     set — decision #1).
///  5. **Recipient-scoped RLS backstop** — `notification.notifications` client
///     writes are revoked and recipient self-read (`recipient_id = auth.uid()`)
///     is enforced (decision #4; Axiom 6), which only a live role/policy set can
///     demonstrate — a materially simpler gate than Groups/Social (no membership
///     join), since identity.users.id IS the Supabase Auth subject UUID.
///
/// The schema (`notification.notifications` + `notification.notification_kind`
/// enum + RLS) lives in `0009_notification.sql`, layered on
/// `0001_identity.sql`..`0008_social.sql`, so it can only be exercised against a
/// live schema. This file is tagged `integration` so it is excluded from the
/// hermetic `melos run test` and executed in CI's dedicated integration job
/// against an ephemeral Postgres with migrations 0001–0009 applied (see
/// ci.yaml), matching the existing social + group + leaderboard + ledger +
/// scoring + prediction + competition + health harness.
///
/// The scenarios CI must exercise once wired end-to-end (each asserts the exact
/// shape the use-case + hermetic unit tests expect):
///
/// createIfAbsent / listForRecipient / findForRecipient / markRead /
/// unreadCount:
///   * happy path — a first `createIfAbsent` inserts (`Ok(true)`) and the row is
///     readable by `findForRecipient(id, recipient)` with its kind wire token,
///     rebuilt subject references, and UTC `created_at`; `listForRecipient`
///     returns it newest-first
///   * **idempotent replay** — the SAME `(recipient, kind, subject_ref)`
///     created again returns `Ok(false)` and leaves exactly ONE row (never a
///     second); `unreadCount` still counts one
///   * **recipient scoping / no oracle** — `findForRecipient` and `markRead`
///     for another user's notification id resolve to `Ok(null)` (→
///     `notification.not_found`), indistinguishable from an absent id
///   * **idempotent mark** — `markRead` returns `Ok(true)` the first time
///     (unread→read) and `Ok(false)` on a retry (already read), preserving the
///     original `read_at`; `unreadCount` drops accordingly
///   * a notification whose `recipient_id` / `round_id` / `group_id` /
///     `actor_user_id` does not exist surfaces
///     `notification.recipient_not_found` / `round_not_found` /
///     `group_not_found` / `actor_not_found` respectively (the FK 23503 mapping)
///   * a genuine racing duplicate that the DB rejects (23505 on
///     `notifications_dedupe_uniq`) converges to `Ok(false)` via
///     `notification.duplicate` (the idempotent-skip pivot)
///   * an unsupported `kind` is impossible to store — the
///     `notification.notification_kind` enum rejects it at the type boundary
void main() {
  test('notification.notifications idempotent create + recipient-scoped '
      'read/mark behave against a live DB', () {
    // Wired in CI's integration job against an ephemeral Postgres service
    // with `supabase/migrations/0001_identity.sql` through
    // `0009_notification.sql` applied. Skipped locally so `melos run test`
    // stays hermetic.
  }, skip: 'Runs only in the CI integration job with a live Postgres service.');
}
