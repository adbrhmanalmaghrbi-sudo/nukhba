-- Migration 0007 — Group (Community) aggregate: private, invite-only social
-- circles that are first-class from the architectural root (Roadmap ADR 0008;
-- Ratified Axiom 2). A Group is an ORTHOGONAL social container — a named circle
-- of platform users identified by their UserId — NOT a competition owner or
-- scope (Groups decision #1, project-context §2). This migration therefore adds
-- ONLY group + membership tables + a per-group role enum; it adds NO group
-- reference to any competition/round/prediction/leaderboard object (those frozen
-- surfaces stay group-free — Axiom 4).
--
-- ADRs / Axioms enforced PHYSICALLY / honoured by this migration:
--
--   * Axiom 2 (private groups first-class): a group is created by exactly one
--     owner and joined only via an unguessable invite code (decisions #2/#3).
--     Membership is member-scoped self-read under RLS — a non-member cannot
--     enumerate or observe a group's existence (no existence oracle).
--
--   * Decision #1 (Group ⊥ Competition): `group.groups` carries NO
--     season/competition/round column; nothing here references the competition
--     schema. The group leaderboard reuses the existing
--     `leaderboard.season_standings` VIEW intersected with membership (a read),
--     introducing no new points source.
--
--   * Decision #2 (roles = owner/member only; instant zero-friction join):
--     `group.group_role` is a closed 2-value enum (NO `admin` tier). The owner
--     membership is written atomically with the group by the backend
--     (`GroupRepository.createGroupWithOwner`); a user is a member at most once
--     (`(group_id, user_id)` unique). Membership is INDEPENDENT of competition
--     `Participant` (no FK to it).
--
--   * Database ADR §10 / Security ADR §2 — the DB is the LAST line of defence.
--     The application enforces the invite capability + owner/member gates FIRST;
--     RLS (member-scoped self-read) + client write-privilege revocation are the
--     backstop (Axiom 6). The backend (service role) bypasses RLS and owns all
--     writes.
--
--   * The adapter (`PostgresGroupRepository`) maps SQLSTATE 23503/23505 by the
--     EXPLICITLY-named constraints below, so those names are part of the
--     contract and must not be renamed without updating the adapter.
--
-- Forward-only, expand-only (Platform ADR). Safe to re-run: every statement is
-- guarded (`create schema/type/table if not exists`, `create or replace
-- function`, `drop … if exists` before policies/triggers). Reuses
-- `identity.set_updated_at` from migration 0001.

-- ---------------------------------------------------------------------------
-- Schema
-- ---------------------------------------------------------------------------
create schema if not exists "group";

comment on schema "group" is
  'Community aggregate (Database ADR §3; Axiom 2): private, invite-only social '
  'circles of platform users. Orthogonal to Competition (decision #1) — holds NO '
  'competition/season/round reference. Owner + member roles only (decision #2).';

-- ---------------------------------------------------------------------------
-- Enumerated domain (closed set — mirrors the domain GroupRole {owner, member};
-- NO `admin` tier for v1, decision #2). An unknown value is a schema violation.
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where t.typname = 'group_role' and n.nspname = 'group'
  ) then
    create type "group".group_role as enum ('owner', 'member');
  end if;
end
$$;

-- ---------------------------------------------------------------------------
-- groups — the Community aggregate root.
--
--   id          — UUID PK (matches the domain GroupId).
--   owner_id    — the sole owner (creator); FK to identity.users ON DELETE
--                 RESTRICT (a group's owner cannot be silently removed —
--                 ownership transfer is not a v1 capability, decision #2). The
--                 constraint is named explicitly for the adapter's 23503 map.
--   name        — display name (1–80 chars enforced by the domain Group.create;
--                 a length CHECK is the backstop).
--   invite_code — the shareable join capability (decision #2/#3); UNIQUE so a
--                 code resolves to at most one group. The unique constraint is
--                 named explicitly for the adapter's 23505 map.
--   created_at / updated_at — audit; updated_at maintained by the shared trigger.
--
-- NO competition/season/round column (decision #1).
-- ---------------------------------------------------------------------------
create table if not exists "group".groups (
  id          uuid primary key,
  owner_id    uuid not null,
  name        text not null,
  invite_code text not null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint groups_owner_id_fkey
    foreign key (owner_id) references identity.users (id) on delete restrict,
  constraint groups_invite_code_key unique (invite_code),
  constraint groups_name_len_chk
    check (char_length(btrim(name)) between 1 and 80)
);

comment on table "group".groups is
  'Group (Community aggregate root). Orthogonal social container: a named circle '
  'of users with one owner and a shareable invite code. Holds NO competition '
  'reference (decision #1). Backend owns all writes (service role); clients may '
  'only read groups they belong to (member-scoped RLS via group_memberships).';

comment on column "group".groups.owner_id is
  'The sole owner (creator). FK to identity.users ON DELETE RESTRICT — a group '
  'always has its owner (decision #2, no ownership transfer in v1).';
comment on column "group".groups.invite_code is
  'The shareable, unguessable join capability (decision #2/#3). UNIQUE so it '
  'resolves to at most one group; rotated by RegenerateInvite (the old code '
  'stops resolving).';

-- ---------------------------------------------------------------------------
-- group_memberships — a user's membership in a group (its own aggregate,
-- separate from the group so a large membership set never locks the group row;
-- mirror of Participant ⟂ Competition, Database ADR §1).
--
--   id         — UUID PK (matches the domain GroupMembershipId).
--   group_id   — FK to group.groups ON DELETE CASCADE (deleting a group removes
--                its memberships); named explicitly for the adapter's 23503 map.
--   user_id    — FK to identity.users ON DELETE RESTRICT (a member row cannot be
--                orphaned); named explicitly for the adapter's 23503 map.
--   role       — per-group role (owner/member — decision #2). Independent of the
--                platform-wide identity.platform_role.
--   joined_at  — UTC join instant (the leaderboard tie-break key; owner joins
--                first when created atomically with the group).
--   created_at / updated_at — audit.
--
-- Uniqueness `(group_id, user_id)` = physical "a user is in a group at most
-- once" (decision #2); named explicitly for the adapter's 23505 map
-- (`group.already_member`, the code JoinGroupByInvite pivots on).
--
-- INDEPENDENT of competition.participants — NO FK to it (decision #2).
-- ---------------------------------------------------------------------------
create table if not exists "group".group_memberships (
  id         uuid primary key,
  group_id   uuid not null,
  user_id    uuid not null,
  role       "group".group_role not null default 'member',
  joined_at  timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint group_memberships_group_id_fkey
    foreign key (group_id) references "group".groups (id) on delete cascade,
  constraint group_memberships_user_id_fkey
    foreign key (user_id) references identity.users (id) on delete restrict,
  constraint group_memberships_group_user_uniq unique (group_id, user_id)
);

comment on table "group".group_memberships is
  'A user''s membership in a group (owner/member — decision #2). Independent of '
  'competition Participant (no FK). (group_id, user_id) is unique = member once. '
  'Backend owns writes; a member may read only the memberships of groups they '
  'themselves belong to.';

-- Serve the member-scoped RLS self-join + the join use-case's membership lookup
-- and the roster listing (by group, joined_at asc). The unique (group_id,
-- user_id) already serves group-scoped and (group,user) lookups; add a by-user
-- index for the "which groups am I in" RLS subquery.
create index if not exists group_memberships_user_idx
  on "group".group_memberships (user_id);

-- ---------------------------------------------------------------------------
-- updated_at maintenance (backstop, Axiom 6) — reuse the shared function from
-- migration 0001 (identity.set_updated_at). The application also sets it on
-- write; the trigger is the last-line guarantee.
-- ---------------------------------------------------------------------------
drop trigger if exists groups_set_updated_at on "group".groups;
create trigger groups_set_updated_at
  before update on "group".groups
  for each row
  execute function identity.set_updated_at();

drop trigger if exists group_memberships_set_updated_at
  on "group".group_memberships;
create trigger group_memberships_set_updated_at
  before update on "group".group_memberships
  for each row
  execute function identity.set_updated_at();

-- ---------------------------------------------------------------------------
-- Row-Level Security (member-scoped self-read; deny client writes).
--
-- The backend uses the service role, which BYPASSES RLS entirely — so these
-- policies constrain ONLY the client-facing (anon / authenticated) surface. A
-- client may READ a group ONLY if they are one of its members, and may READ a
-- membership row ONLY of a group they themselves belong to — so a non-member
-- learns nothing about a group's existence (no enumeration oracle, decision #3).
-- There is deliberately NO client insert/update/delete policy: with RLS enabled
-- and no permissive write policy, all client writes are denied. Direct write
-- privileges are also revoked defensively (permission revocation as the last
-- line — Security ADR §2 / DB ADR §10).
-- ---------------------------------------------------------------------------
alter table "group".groups enable row level security;
alter table "group".group_memberships enable row level security;

revoke insert, update, delete, truncate on "group".groups
  from anon, authenticated;
revoke insert, update, delete, truncate on "group".group_memberships
  from anon, authenticated;
grant select on "group".groups to authenticated;
grant select on "group".group_memberships to authenticated;

-- A signed-in user may read a group ONLY if they are a member of it.
drop policy if exists groups_select_member on "group".groups;
create policy groups_select_member
  on "group".groups
  for select
  to authenticated
  using (
    exists (
      select 1
      from "group".group_memberships m
      where m.group_id = groups.id
        and m.user_id = auth.uid()
    )
  );

-- A signed-in user may read membership rows ONLY of a group they belong to
-- (so they can see who else is in their own circle, but nothing about groups
-- they are not in). The self-join is on the same table via a correlated EXISTS.
drop policy if exists group_memberships_select_comember
  on "group".group_memberships;
create policy group_memberships_select_comember
  on "group".group_memberships
  for select
  to authenticated
  using (
    exists (
      select 1
      from "group".group_memberships self
      where self.group_id = group_memberships.group_id
        and self.user_id = auth.uid()
    )
  );

-- Anonymous callers get nothing from either table.
drop policy if exists groups_anon_no_access on "group".groups;
create policy groups_anon_no_access
  on "group".groups
  for select
  to anon
  using (false);

drop policy if exists group_memberships_anon_no_access
  on "group".group_memberships;
create policy group_memberships_anon_no_access
  on "group".group_memberships
  for select
  to anon
  using (false);
