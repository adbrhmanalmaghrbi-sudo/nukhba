-- Migration 0009 — Notification aggregate: the single in-app notification
-- surface (Roadmap ADR 0008; Database ADR 0003 §2.2/§2.4/§3). Notification is a
-- Tier-3 PERIPHERAL aggregate — rebuildable, per-user, NEVER a source of truth
-- (Deployment ADR 0007 §2.4 Tier-3: explicitly allowed to degrade; the
-- integrity-critical core — Prediction/Scoring/Ledger — never blocks on it).
--
-- Unlike Social's Activity Feed (Social decision #2 — a pure read projection
-- with NO table), a notification carries genuinely stored, per-user, MUTABLE
-- read-state (Notifications decision #3), so this phase adds exactly ONE new
-- stored table — `notification.notifications` — plus its closed
-- `notification.notification_kind` enum. No projection helper table is needed.
--
-- This migration realises PHYSICALLY the exact shape
-- `PostgresNotificationRepository` (packages/infrastructure) already assumes.
-- The constraint names below (`notifications_dedupe_uniq` and the four
-- `notifications_*_fkey`) are part of the adapter contract — the adapter's
-- `ON CONFLICT ON CONSTRAINT notifications_dedupe_uniq DO NOTHING` and its
-- SQLSTATE 23505/23503 → typed-error map key off these exact names, so they
-- MUST NOT be renamed without updating the adapter in lockstep.
--
-- ADRs / Axioms enforced PHYSICALLY / honoured by this migration:
--
--   * Axiom 5 (points are the protected record; Notifications is never a second
--     points source): `notification.notifications` carries NO amount/points
--     column. Nothing here writes to ledger/scoring/leaderboard.
--
--   * Decision #1 (a bounded, closed trigger surface; NO free text / open
--     graph): `kind` is a closed `notification.notification_kind` enum with
--     exactly the three ratified kinds (mirrors the domain NotificationKind
--     wire tokens {round_scored, group_member_joined, reaction_received}).
--     There is NO free-text/body column and NO follow/friend edge — the
--     kind-specific references (round/group/actor) are the only payload, and
--     the copy a user sees is a CLIENT presentation concern (decision #1).
--
--   * Decision #3 (the ONE new stored surface; genuinely stored, MUTABLE
--     read-state): exactly one table is created; `read_at` is the sole mutable
--     column (NULL = unread, a UTC instant = read). A recipient has AT MOST ONE
--     notification per distinct event — uniqueness
--     `(recipient_id, kind, subject_ref)` (`notifications_dedupe_uniq`) makes a
--     replayed trigger an idempotent `INSERT … ON CONFLICT DO NOTHING`
--     (the adapter's `createIfAbsent`), never a second row.
--
--   * Decision #4 (recipient-scoped; no existence oracle): every notification
--     belongs to exactly one `recipient_id`; RLS is recipient self-read
--     (`recipient_id = auth.uid()`) — a materially SIMPLER gate than Groups /
--     Social (no membership join), because `identity.users.id` IS the Supabase
--     Auth subject UUID (migration 0001). A foreign id is invisible to a client
--     (no enumeration oracle) and the recipient-scoped adapter reads/mark
--     enforce the same in the service tier.
--
--   * Database ADR §10 / Security ADR §2 — the DB is the LAST line of defence.
--     The application enforces "caller == recipient" FIRST; RLS (recipient
--     self-read) + client write-privilege revocation are the backstop (Axiom 6).
--     The backend (service role) bypasses RLS and owns all writes; the recipient
--     is bound server-side from the ratified trigger, never a request body.
--
-- Forward-only, expand-only (Platform ADR). Safe to re-run: every statement is
-- guarded (`create schema/type/table if not exists`, `drop … if exists` before
-- policies). No `updated_at` column exists on this table (the only mutable state
-- is `read_at`, set explicitly by the adapter's recipient-scoped mark), so —
-- unlike social.reactions / group tables — NO `set_updated_at` trigger is
-- attached here.

-- ---------------------------------------------------------------------------
-- Schema
-- ---------------------------------------------------------------------------
create schema if not exists notification;

comment on schema notification is
  'Notification aggregate (Database ADR §2.2/§3): Tier-3, rebuildable, '
  'per-user, NEVER a source of truth. Holds the ONE new stored surface — '
  'notifications (decision #3, genuinely stored MUTABLE read-state). NO points '
  'column (Axiom 5), NO free-text/open-graph edge (decision #1 / ADR-001).';

-- ---------------------------------------------------------------------------
-- Enumerated domain (closed set — mirrors the domain NotificationKind wire
-- tokens {round_scored, group_member_joined, reaction_received}; decision #1:
-- NO free text, a minimal high-value trigger surface, NOT every domain event).
-- An unknown value is a schema violation. Extending the set is a forward-only
-- enum change (`alter type … add value`), exactly as the domain enum documents.
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where t.typname = 'notification_kind' and n.nspname = 'notification'
  ) then
    create type notification.notification_kind as enum
      ('round_scored', 'group_member_joined', 'reaction_received');
  end if;
end
$$;

-- ---------------------------------------------------------------------------
-- notifications — a single in-app notification addressed to exactly one
-- recipient (the ONE new stored Tier-3 surface — decision #3).
--
--   id            — UUID PK (matches the domain NotificationId).
--   recipient_id  — the single addressee; the ONLY user who may read/mark it
--                   (decision #4). FK to identity.users ON DELETE CASCADE
--                   (deleting a user removes their notifications); named
--                   explicitly for the adapter's 23503 map
--                   (`notification.recipient_not_found`).
--   kind          — the closed enum discriminant (decision #1); drives which of
--                   the nullable reference columns below are populated.
--   round_id      — the referenced round for `round_scored` / `reaction_received`
--                   (else NULL). FK to competition.rounds ON DELETE CASCADE; the
--                   link is FROM notification TO competition — no notification
--                   ref is ever added to a Round (Axiom 4 / decision #1). Named
--                   explicitly for the adapter's 23503 map.
--   group_id      — the referenced group for `group_member_joined` /
--                   `reaction_received` (else NULL). FK to "group".groups
--                   ON DELETE CASCADE; named explicitly for the 23503 map.
--   actor_user_id — the acting user for `group_member_joined` (the joiner) /
--                   `reaction_received` (the reactor) (else NULL). FK to
--                   identity.users ON DELETE CASCADE; named explicitly for the
--                   23503 map. It is a DISTINCT FK from recipient_id.
--   subject_ref   — the deterministic NotificationSubject.dedupeRef (e.g.
--                   'round:<uuid>', 'group_join:<g>:<a>',
--                   'reaction:<g>:<r>:<a>'); the idempotency key component so a
--                   replayed trigger dedupes and a distinct event does not.
--   read_at       — the SOLE mutable column: NULL while unread, a UTC instant
--                   once the recipient marks it read (decision #3). The mark is
--                   idempotent (adapter guards `read_at IS NULL`).
--   created_at    — UTC instant of creation — the newest-first ordering key
--                   (the adapter lists `ORDER BY created_at DESC, id DESC`).
--
-- Uniqueness `(recipient_id, kind, subject_ref)` = physical "at most one
-- notification per recipient per distinct event" (decision #3); named
-- explicitly `notifications_dedupe_uniq` — the adapter's
-- `ON CONFLICT ON CONSTRAINT notifications_dedupe_uniq DO NOTHING` target and
-- its 23505 → `notification.duplicate` (idempotent-skip) map both key off it.
--
-- NO points/amount column (Axiom 5). NO free-text/body column, NO open-graph
-- edge (decision #1 / ADR-001). NO updated_at (only read_at mutates).
-- ---------------------------------------------------------------------------
create table if not exists notification.notifications (
  id            uuid primary key,
  recipient_id  uuid not null,
  kind          notification.notification_kind not null,
  round_id      uuid,
  group_id      uuid,
  actor_user_id uuid,
  subject_ref   text not null,
  read_at       timestamptz,
  created_at    timestamptz not null default now(),
  constraint notifications_recipient_id_fkey
    foreign key (recipient_id) references identity.users (id) on delete cascade,
  constraint notifications_round_id_fkey
    foreign key (round_id) references competition.rounds (id) on delete cascade,
  constraint notifications_group_id_fkey
    foreign key (group_id) references "group".groups (id) on delete cascade,
  constraint notifications_actor_user_id_fkey
    foreign key (actor_user_id) references identity.users (id) on delete cascade,
  constraint notifications_dedupe_uniq
    unique (recipient_id, kind, subject_ref)
);

comment on table notification.notifications is
  'A single in-app notification to one recipient (Tier-3, decision #3). '
  '(recipient_id, kind, subject_ref) is unique = at most one notification per '
  'recipient per distinct event (a replayed trigger is an idempotent '
  'ON CONFLICT DO NOTHING skip, never a second row). read_at is the only '
  'mutable column (NULL = unread). Carries NO points (Axiom 5) and NO '
  'free-text/open-graph edge (decision #1 / ADR-001). Backend owns writes; a '
  'user reads/marks only their own notifications (recipient-only gate, no '
  'existence oracle).';

comment on column notification.notifications.recipient_id is
  'The single addressee — the ONLY user who may read/mark this (decision #4). '
  'Bound server-side from the ratified trigger, never a request body.';
comment on column notification.notifications.round_id is
  'Referenced round (round_scored / reaction_received). The link is FROM '
  'notification TO competition — no notification reference is ever added to a '
  'Round (Axiom 4 / decision #1).';
comment on column notification.notifications.subject_ref is
  'Deterministic NotificationSubject.dedupeRef; the idempotency-key component '
  'of notifications_dedupe_uniq so a replayed trigger dedupes.';
comment on column notification.notifications.read_at is
  'The sole mutable column: NULL while unread, a UTC instant once read. The '
  'recipient-scoped mark is idempotent (guards read_at IS NULL).';

-- ---------------------------------------------------------------------------
-- Indexes. The unique (recipient_id, kind, subject_ref) already covers the
-- dedupe conflict probe and any recipient-prefix scan. The two hot recipient
-- reads are (a) the newest-first list — `WHERE recipient_id = ? ORDER BY
-- created_at DESC, id DESC` — and (b) the unread count — `WHERE recipient_id = ?
-- AND read_at IS NULL`. Serve (a) with a recipient+created_at index matching the
-- ORDER BY direction, and (b) with a partial index over unread rows only (keeps
-- the count probe tiny — read rows are excluded from the index).
-- ---------------------------------------------------------------------------
create index if not exists notifications_recipient_created_idx
  on notification.notifications (recipient_id, created_at desc, id desc);

create index if not exists notifications_recipient_unread_idx
  on notification.notifications (recipient_id)
  where read_at is null;

-- ---------------------------------------------------------------------------
-- Row-Level Security (recipient self-read; deny client writes).
--
-- The backend uses the service role, which BYPASSES RLS entirely — so these
-- policies constrain ONLY the client-facing (anon / authenticated) surface. A
-- client may READ a notification ONLY if they are its recipient
-- (`recipient_id = auth.uid()`, decision #4) — a materially simpler gate than
-- Groups/Social (no membership join), because identity.users.id IS the Supabase
-- Auth subject UUID (migration 0001). So a user learns nothing about another
-- user's notifications (no enumeration oracle). There is deliberately NO client
-- insert/update/delete policy: with RLS enabled and no permissive write policy,
-- all client writes are denied. Direct write privileges are also revoked
-- defensively (Security ADR §2 / DB ADR §10) — including the recipient's own
-- read-state mark, which flows through the backend (service role), never a
-- direct client UPDATE.
-- ---------------------------------------------------------------------------
alter table notification.notifications enable row level security;

revoke insert, update, delete, truncate on notification.notifications
  from anon, authenticated;
grant select on notification.notifications to authenticated;

-- A signed-in user may read a notification ONLY if they are its recipient.
drop policy if exists notifications_select_recipient on notification.notifications;
create policy notifications_select_recipient
  on notification.notifications
  for select
  to authenticated
  using (recipient_id = auth.uid());

-- Anonymous callers get nothing.
drop policy if exists notifications_anon_no_access on notification.notifications;
create policy notifications_anon_no_access
  on notification.notifications
  for select
  to anon
  using (false);
