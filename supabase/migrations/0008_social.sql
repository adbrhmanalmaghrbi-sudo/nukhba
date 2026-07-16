-- Migration 0008 — Social (Engagement) aggregate: emoji Reactions to a
-- round-result within a private group (Roadmap ADR 0008; Database ADR 0003 §3).
-- Social is a Tier-3 PERIPHERAL aggregate — rebuildable, group-scoped, NEVER a
-- source of truth (Deployment ADR 0007 §Tier-3: explicitly allowed to degrade;
-- the integrity-critical core never blocks on it). This migration adds ONLY the
-- ONE new stored Tier-3 surface ratified for v1 — `social.reactions` — plus its
-- closed `social.reaction_kind` enum. The Activity Feed needs NO table (Social
-- decision #2 — it is a pure read projection over already-ratified
-- group/competition/ledger/leaderboard data), so nothing is added for it here.
--
-- ADRs / Axioms enforced PHYSICALLY / honoured by this migration:
--
--   * Axiom 5 (points are the protected record; Social is never a second points
--     source): `social.reactions` carries NO amount/points column. Nothing here
--     writes to ledger/scoring/leaderboard.
--
--   * Decision #1 (bounded reactions, NO free text; round-scored, NO open
--     graph): the emoji is a closed `social.reaction_kind` enum (mirrors the
--     domain ReactionKind {like,fire,clap,laugh,sad,shock}); the reaction
--     targets a round via `round_id`. There is NO free-text column and NO
--     follow/friend edge (ADR-001 exclusion / ADR-006 §2.6 — a group is the
--     only social container).
--
--   * Decision #2 (Reactions = the ONE new stored surface; Feed = projection):
--     exactly one table is created. A member has AT MOST ONE live reaction per
--     round-result within a group — uniqueness `(group_id, round_id, user_id)`
--     makes a re-react an idempotent upsert (the adapter's ON CONFLICT target),
--     never a second row.
--
--   * Decision #3 (group-scoped visibility, no existence oracle): every reaction
--     is `group_id`-scoped and RLS is member-scoped self-read reusing the exact
--     Groups member self-join — a non-member cannot enumerate or observe a
--     group's reactions (no oracle).
--
--   * Database ADR §10 / Security ADR §2 — the DB is the LAST line of defence.
--     The application enforces the group-member gate FIRST; RLS (member-scoped
--     self-read) + client write-privilege revocation are the backstop (Axiom 6).
--     The backend (service role) bypasses RLS and owns all writes.
--
--   * The adapter (`PostgresReactionRepository`) maps SQLSTATE 23503/23505 by
--     the EXPLICITLY-named constraints below, so those names are part of the
--     contract and must not be renamed without updating the adapter.
--
-- Forward-only, expand-only (Platform ADR). Safe to re-run: every statement is
-- guarded (`create schema/type/table if not exists`, `create or replace
-- function`, `drop … if exists` before policies/triggers). Reuses
-- `identity.set_updated_at` from migration 0001.

-- ---------------------------------------------------------------------------
-- Schema
-- ---------------------------------------------------------------------------
create schema if not exists social;

comment on schema social is
  'Engagement/Social aggregate (Database ADR §3): Tier-3, rebuildable, '
  'group-scoped, NEVER a source of truth. Holds the ONE new stored surface — '
  'reactions (decision #2). The Activity Feed is a pure projection (no table). '
  'NO points column (Axiom 5), NO open-graph edge (ADR-001).';

-- ---------------------------------------------------------------------------
-- Enumerated domain (closed set — mirrors the domain ReactionKind
-- {like, fire, clap, laugh, sad, shock}; decision #1: NO free text). An unknown
-- value is a schema violation. Extending the set is a forward-only enum change.
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where t.typname = 'reaction_kind' and n.nspname = 'social'
  ) then
    create type social.reaction_kind as enum
      ('like', 'fire', 'clap', 'laugh', 'sad', 'shock');
  end if;
end
$$;

-- ---------------------------------------------------------------------------
-- reactions — a member's emoji reaction to a round-result within a group (the
-- ONE new stored Tier-3 surface — decision #2).
--
--   id         — UUID PK (matches the domain ReactionId).
--   group_id   — the social container; FK to group.groups ON DELETE CASCADE
--                (deleting a group removes its reactions); named explicitly for
--                the adapter's 23503 map.
--   round_id   — the target round-result; FK to competition.rounds ON DELETE
--                CASCADE (a removed round takes its reactions with it); named
--                explicitly for the adapter's 23503 map. This is the ONLY link
--                to a core object and it is FROM social TO competition — no
--                group/social ref is ever added to a Round (decision #1).
--   user_id    — the reacting member (bound from the verified token by the
--                use-case, never a request body); FK to identity.users ON DELETE
--                RESTRICT; named explicitly for the adapter's 23503 map.
--   emoji      — the chosen reaction from the closed enum (decision #1).
--   reacted_at — UTC instant of the reaction (or its last change) — the feed's
--                chronological key.
--   created_at / updated_at — audit; updated_at maintained by the shared trigger.
--
-- Uniqueness `(group_id, round_id, user_id)` = physical "one live reaction per
-- member per round-result within a group" (decision #1/#2); named explicitly for
-- the adapter's 23505 map (`social.reaction_conflict`, the upsert converges on).
--
-- NO points/amount column (Axiom 5). NO free-text column, NO open-graph edge
-- (decision #1 / ADR-001).
-- ---------------------------------------------------------------------------
create table if not exists social.reactions (
  id         uuid primary key,
  group_id   uuid not null,
  round_id   uuid not null,
  user_id    uuid not null,
  emoji      social.reaction_kind not null,
  reacted_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint reactions_group_id_fkey
    foreign key (group_id) references "group".groups (id) on delete cascade,
  constraint reactions_round_id_fkey
    foreign key (round_id) references competition.rounds (id) on delete cascade,
  constraint reactions_user_id_fkey
    foreign key (user_id) references identity.users (id) on delete restrict,
  constraint reactions_group_round_user_uniq unique (group_id, round_id, user_id)
);

comment on table social.reactions is
  'A member''s single emoji reaction to a round-result within a group (Tier-3, '
  'decision #2). (group_id, round_id, user_id) is unique = one live reaction per '
  'member per round-result (re-react = idempotent upsert). Carries NO points '
  '(Axiom 5) and NO open-graph edge (ADR-001). Backend owns writes; a member '
  'reads only reactions in groups they belong to.';

comment on column social.reactions.round_id is
  'The target round-result. The link is FROM social TO competition — no '
  'group/social reference is ever added to a Round (decision #1).';

-- Serve the group+round list read and the member-scoped RLS self-join. The
-- unique (group_id, round_id, user_id) already serves the exact-key upsert
-- lookup and (group_id, round_id, …) prefix scans; add a by-user index for the
-- "which groups am I in" RLS subquery reuse pattern is unnecessary here (the
-- RLS join hits group.group_memberships, indexed in 0007). The composite unique
-- index covers listReactionsForRound's (group_id, round_id) predicate.

-- ---------------------------------------------------------------------------
-- updated_at maintenance (backstop, Axiom 6) — reuse the shared function from
-- migration 0001 (identity.set_updated_at). The application also refreshes
-- reacted_at on a change; the trigger is the last-line guarantee for updated_at.
-- ---------------------------------------------------------------------------
drop trigger if exists reactions_set_updated_at on social.reactions;
create trigger reactions_set_updated_at
  before update on social.reactions
  for each row
  execute function identity.set_updated_at();

-- ---------------------------------------------------------------------------
-- Row-Level Security (member-scoped self-read; deny client writes).
--
-- The backend uses the service role, which BYPASSES RLS entirely — so these
-- policies constrain ONLY the client-facing (anon / authenticated) surface. A
-- client may READ a reaction ONLY if they are a member of the group it belongs
-- to (reusing the exact Groups member self-join, decision #3) — so a non-member
-- learns nothing about a group's reactions (no enumeration oracle). There is
-- deliberately NO client insert/update/delete policy: with RLS enabled and no
-- permissive write policy, all client writes are denied. Direct write
-- privileges are also revoked defensively (Security ADR §2 / DB ADR §10).
-- ---------------------------------------------------------------------------
alter table social.reactions enable row level security;

revoke insert, update, delete, truncate on social.reactions
  from anon, authenticated;
grant select on social.reactions to authenticated;

-- A signed-in user may read a reaction ONLY if they are a member of its group.
drop policy if exists reactions_select_member on social.reactions;
create policy reactions_select_member
  on social.reactions
  for select
  to authenticated
  using (
    exists (
      select 1
      from "group".group_memberships m
      where m.group_id = reactions.group_id
        and m.user_id = auth.uid()
    )
  );

-- Anonymous callers get nothing.
drop policy if exists reactions_anon_no_access on social.reactions;
create policy reactions_anon_no_access
  on social.reactions
  for select
  to anon
  using (false);
