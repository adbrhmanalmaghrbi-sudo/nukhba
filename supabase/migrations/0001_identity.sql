-- Migration 0001 — Identity aggregate: the canonical, platform-owned user row.
--
-- ADRs enforced by this migration:
--   * Database ADR, Section 3  — `User` is the Identity aggregate root; its id
--     equals the Supabase Auth subject UUID (the JWT `sub`).
--   * Database ADR, Section 10 — the database is the LAST line of defence, not
--     the first: the application enforces invariants, and DB triggers /
--     permission revocation are the backstop (Ratified Axiom 6).
--   * Security ADR, Section 2  — three trust zones. The backend holds the
--     service role and bypasses RLS (it bears full invariant responsibility);
--     every client-facing surface is untrusted and guarded by RLS. This table
--     is Tier-1 (integrity-critical): clients may READ their own row but may
--     NEVER write it — role/status are administered by the platform only.
--
-- Forward-only, expand-only (Platform ADR, Section: forward-only migrations,
-- expand-contract discipline). Safe to re-run: every statement is guarded.

-- ---------------------------------------------------------------------------
-- Schema
-- ---------------------------------------------------------------------------
create schema if not exists identity;

comment on schema identity is
  'Identity aggregate (Database ADR §3): platform-owned user records. The '
  'Supabase-managed auth.users table owns credentials; this schema owns the '
  'platform''s canonical projection (role, status).';

-- ---------------------------------------------------------------------------
-- Enumerated domains (closed sets — an unknown value is a schema violation,
-- mirroring the closed enums in the domain layer: PlatformRole, UserStatus).
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where t.typname = 'platform_role' and n.nspname = 'identity'
  ) then
    create type identity.platform_role as enum ('user', 'admin', 'service');
  end if;

  if not exists (
    select 1 from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where t.typname = 'user_status' and n.nspname = 'identity'
  ) then
    create type identity.user_status as enum ('active', 'suspended');
  end if;
end
$$;

-- ---------------------------------------------------------------------------
-- Canonical users table
-- ---------------------------------------------------------------------------
create table if not exists identity.users (
  -- Primary key IS the Supabase Auth subject UUID (Database ADR §3). The FK to
  -- auth.users keeps the platform projection in lockstep with the identity
  -- provider; deleting the auth user cascades to remove the platform row.
  id         uuid primary key
             references auth.users (id) on delete cascade,
  email      text,
  role       identity.platform_role not null default 'user',
  status     identity.user_status   not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table identity.users is
  'Canonical platform user (Identity aggregate root). role/status are '
  'platform-owned and authoritative over token claims once the row exists; '
  'the backend upserts via service role, clients may only read their own row.';

comment on column identity.users.id is
  'Supabase Auth subject UUID (JWT sub); FK to auth.users.';
comment on column identity.users.role is
  'Coarse platform authority (first authorization layer). Never set from a '
  'client; elevation to admin is a platform decision.';
comment on column identity.users.status is
  'Lifecycle state governing whether the user may act. Suspension is enforced '
  'by the application; this column is the backstop record.';

-- Case-insensitive lookup by email (nullable emails are simply not indexed).
create unique index if not exists users_email_lower_uidx
  on identity.users (lower(email))
  where email is not null;

-- ---------------------------------------------------------------------------
-- updated_at maintenance (backstop): keep the column honest even if a writer
-- forgets to set it. The application also sets it on upsert; this trigger is
-- the last-line guarantee (Axiom 6).
-- ---------------------------------------------------------------------------
create or replace function identity.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists users_set_updated_at on identity.users;
create trigger users_set_updated_at
  before update on identity.users
  for each row
  execute function identity.set_updated_at();

-- ---------------------------------------------------------------------------
-- Row-Level Security (Tier-1: deny client writes, allow self-read).
--
-- The backend uses the service role, which BYPASSES RLS entirely — so these
-- policies constrain ONLY the client-facing (anon / authenticated) surface,
-- exactly as intended by the Security ADR. There is deliberately NO insert /
-- update / delete policy for the `authenticated` role: with RLS enabled and no
-- permissive write policy, all client writes are denied by default.
-- ---------------------------------------------------------------------------
alter table identity.users enable row level security;

-- Defensive: revoke direct write privileges from client roles so even a future
-- mis-added policy cannot silently grant writes (permission revocation as the
-- last line, Security ADR §2 / DB ADR §10).
revoke insert, update, delete, truncate on identity.users
  from anon, authenticated;
grant select on identity.users to authenticated;

-- A signed-in user may read ONLY their own canonical row.
drop policy if exists users_select_self on identity.users;
create policy users_select_self
  on identity.users
  for select
  to authenticated
  using (id = auth.uid());

-- Anonymous callers get nothing.
drop policy if exists users_anon_no_access on identity.users;
create policy users_anon_no_access
  on identity.users
  for select
  to anon
  using (false);
