-- Migration 0010 — Admin aggregate: the ONE general, append-only admin audit
-- trail (Roadmap ADR 0008 phase 11; Database ADR 0003 §10; Security ADR 0006
-- §2.2/§2.4/§4). Admin Panel decision OPEN-B: a SINGLE append-only
-- `admin.audit_log` table covering ALL admin actions (its own migration,
-- mirroring how 0009_notification.sql added exactly one new table), append-only
-- only. This is the phase's ONLY new stored surface — the user sanction reuses
-- the existing identity.users row (no new table; migration 0001 already carries
-- the `suspended` status the sanction toggles), and every reused
-- competition/scoring/ledger admin command writes to its own already-shipped
-- table. So Admin Panel adds exactly one table: the audit log.
--
-- This migration realises PHYSICALLY the exact shape
-- `PostgresAuditLogRepository` (packages/infrastructure/lib/src/admin) already
-- assumes. The constraint names below (`audit_log_pkey`,
-- `audit_log_actor_id_fkey`) are part of the adapter contract — the adapter's
-- SQLSTATE 23505/23503 → typed-error map keys off these exact names, so they
-- MUST NOT be renamed without updating the adapter in lockstep. The
-- `admin.audit_action` enum values are the domain `AuditAction.wireValue`
-- tokens, one-to-one.
--
-- ADRs / Axioms enforced PHYSICALLY / honoured by this migration:
--
--   * Axiom 5 (points are the protected record; the audit log is NEVER a second
--     points source): `admin.audit_log` carries NO amount/points column. It
--     only OBSERVES actions; the link is FROM the audit row TO an opaque
--     `target_ref`, never a foreign key onto a core aggregate (the audit log is
--     peripheral to the entities it records — nothing in competition/scoring/
--     ledger references it back).
--
--   * Decision OPEN-B #1/#2 (ONE table, ALL admin actions): a single table with
--     a closed `admin.audit_action` enum spanning the two genuinely-new
--     capabilities (user_suspended / user_reinstated), the narrow support read
--     (participant_ledger_viewed), and the reused crown-jewel + authoring
--     commands (fixture_result_recorded, round_scored, round_posted_to_ledger,
--     competition_created, season_started, round_opened, round_locked,
--     fixture_linked_to_round). Extending it (a new admin capability) is a
--     forward-only `alter type … add value` + enum change, exactly as the
--     domain AuditAction enum documents.
--
--   * Decision OPEN-B #3 (append-only only): once written, an audit row is
--     NEVER edited or removed — by ANY role, including the RLS-bypassing
--     backend service role. This is layered (Axiom 6): (a) the application only
--     ever calls `append`; (b) UPDATE/DELETE/TRUNCATE are revoked from every
--     client role; (c) an immutability trigger (`admin.reject_audit_mutation`)
--     rejects UPDATE/DELETE for EVERY role as the strongest backstop, mirroring
--     ledger.reject_entry_mutation. There is deliberately NO cryptographic
--     signing / external log service (decision OPEN-B #3: that is over-
--     engineering for v1 scope).
--
--   * Security ADR §2.4 / §4 (attributable, immutable trace): every row names
--     WHO (actor_id → identity.users), WHAT (action), TO WHICH ENTITY
--     (target_ref), WHEN (occurred_at), and WHY (reason, mandatory for a
--     sanction — enforced by the use-case + domain AuditEntry.create, non-blank
--     when present here). The audit read is admin-only, enforced in the
--     `ListAuditLog` use-case (PlatformRole.admin); it is NEVER a client-
--     readable surface (unlike notifications' recipient self-read), so RLS here
--     is deny-all to every client role — the backend service role reads it.
--
--   * Database ADR §10 / Security ADR §2 — the DB is the LAST line of defence.
--     The application enforces admin authority + the mandatory reason FIRST;
--     RLS deny-all + privilege revocation + the immutability trigger are the
--     backstop (Axiom 6). The actor is bound server-side from the verified
--     token, never a request body.
--
-- Forward-only, expand-only (Platform ADR). Safe to re-run: every statement is
-- guarded (`create schema/type/table if not exists`, `create or replace
-- function`, `drop … if exists` before triggers/policies). The audit row is
-- immutable, so there is NO `updated_at` column and NO set_updated_at trigger.

-- ---------------------------------------------------------------------------
-- Schema
-- ---------------------------------------------------------------------------
create schema if not exists admin;

comment on schema admin is
  'Admin aggregate (Database ADR §10; Security ADR §2.2/§2.4): the ONE general '
  'append-only audit trail of privileged admin actions (decision OPEN-B). '
  'NEVER a source of truth for points (Axiom 5) — it only observes. NO client '
  'reads it (admin-only via the backend); it can only grow by appends.';

-- ---------------------------------------------------------------------------
-- Enumerated domain (closed set — mirrors the domain AuditAction wire tokens
-- one-to-one; decision OPEN-B #2: covers ALL admin actions). An unknown value
-- is a schema violation. Extending the set (a new admin capability) is a
-- forward-only `alter type … add value`, exactly as the domain enum documents.
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where t.typname = 'audit_action' and n.nspname = 'admin'
  ) then
    create type admin.audit_action as enum (
      'user_suspended',
      'user_reinstated',
      'participant_ledger_viewed',
      'fixture_result_recorded',
      'round_scored',
      'round_posted_to_ledger',
      'competition_created',
      'season_started',
      'round_opened',
      'round_locked',
      'fixture_linked_to_round'
    );
  end if;
end
$$;

-- ---------------------------------------------------------------------------
-- audit_log — one immutable record of a privileged admin action (the ONE new
-- stored surface this phase adds — decision OPEN-B #1).
--
--   id          — UUID PK (matches the domain AuditEntryId). Named
--                 `audit_log_pkey` (the default) — the adapter's 23505 map
--                 keys off this exact name (a duplicate server-generated id is
--                 a defensive backstop → admin.audit_duplicate).
--   actor_id    — the acting admin's platform user id (attributability —
--                 Security ADR §2.4). FK to identity.users ON DELETE RESTRICT:
--                 the audit trail must NOT lose its actor — deleting a user who
--                 has audit history is refused (unlike notifications' CASCADE,
--                 whose per-user rows are disposable Tier-3 data). Named
--                 explicitly `audit_log_actor_id_fkey` for the adapter's 23503
--                 map (admin.audit_actor_not_found).
--   action      — the closed enum discriminant (decision OPEN-B #2).
--   target_ref  — an opaque, human-readable reference to the entity acted on
--                 (e.g. a user id, participant id, or a composite). NOT a
--                 foreign key: different actions target different aggregates,
--                 and the audit log never constrains the entities it observes
--                 (Axiom 5 — the link is FROM the log TO the ref, never the
--                 reverse). NOT NULL — an audit row always names its subject.
--   reason      — the justification: NOT NULL-constrained is deliberately NOT
--                 imposed here (a support read carries none — decision OPEN-A
--                 #3), but a sanction's reason is mandatory, enforced by the
--                 use-case (SuspendUser) + domain AuditEntry.create. A stored
--                 value, when present, is non-blank (the domain guarantees it).
--   occurred_at — UTC instant of the action — the newest-first ordering key
--                 (the adapter lists `ORDER BY occurred_at DESC, id DESC`).
--
-- NO points/amount column (Axiom 5). NO updated_at (the row is immutable).
-- ---------------------------------------------------------------------------
create table if not exists admin.audit_log (
  id          uuid primary key,
  actor_id    uuid not null,
  action      admin.audit_action not null,
  target_ref  text not null,
  reason      text,
  occurred_at timestamptz not null default now(),
  constraint audit_log_actor_id_fkey
    foreign key (actor_id) references identity.users (id) on delete restrict,
  -- A stored reason, when present, is non-blank (the domain refuses a blank
  -- supplied reason; this is the physical backstop — Axiom 6).
  constraint audit_log_reason_not_blank
    check (reason is null or length(btrim(reason)) > 0),
  -- A target_ref is always a non-blank reference.
  constraint audit_log_target_ref_not_blank
    check (length(btrim(target_ref)) > 0)
);

comment on table admin.audit_log is
  'The ONE general append-only admin audit trail (decision OPEN-B): who did '
  'what, to which entity, when, and why. Covers ALL admin actions. Append-only '
  'for EVERY role (revoked UPDATE/DELETE + an immutability trigger — Axiom '
  '5/6). Carries NO points (Axiom 5). actor_id is RESTRICT (the trail never '
  'loses its actor); target_ref is an opaque provenance ref, never a FK onto a '
  'core aggregate. Read is admin-only via the backend — no client reads it.';

comment on column admin.audit_log.actor_id is
  'The acting admin''s platform user id (attributability — Security ADR §2.4). '
  'Bound server-side from the verified token, never a request body. '
  'ON DELETE RESTRICT: the trail must not lose its actor.';
comment on column admin.audit_log.target_ref is
  'Opaque, human-readable reference to the entity acted on (provenance, not a '
  'foreign key). The link is FROM the audit log TO the ref, never the reverse '
  '(Axiom 5 — the audit log is peripheral to the entities it observes).';
comment on column admin.audit_log.reason is
  'The justification. Mandatory for a sanction (enforced by SuspendUser + '
  'AuditEntry.create); optional for a support read (decision OPEN-A #3). '
  'Non-blank when present (the check constraint is the physical backstop).';

-- ---------------------------------------------------------------------------
-- Index. The single hot read is the newest-first trail — `ORDER BY occurred_at
-- DESC, id DESC LIMIT ?` (the adapter's `list`). Serve it with an index that
-- matches the ORDER BY direction so the bounded read is index-only on the
-- ordering keys.
-- ---------------------------------------------------------------------------
create index if not exists audit_log_occurred_idx
  on admin.audit_log (occurred_at desc, id desc);

-- ---------------------------------------------------------------------------
-- IMMUTABILITY trigger (decision OPEN-B #3; Axiom 5/6 — the strongest
-- backstop). The audit trail is append-only: no row may EVER be updated or
-- deleted, by ANY role, including the backend service role that bypasses RLS.
-- RLS + privilege revocation stop the client; this trigger stops even a buggy
-- or compromised backend, so the accountability record can only ever grow by
-- appends. Mirrors ledger.reject_entry_mutation exactly.
--
-- Raised as a check_violation so a violation the adapter ever sees maps to an
-- integrity error (the application never issues UPDATE/DELETE on the audit log,
-- so in practice this never fires from our code — it is the last line of
-- defence).
-- ---------------------------------------------------------------------------
create or replace function admin.reject_audit_mutation()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'UPDATE' then
    raise exception
      'admin.audit_log is append-only: UPDATE is forbidden (decision OPEN-B #3)'
      using errcode = 'check_violation';
  elsif tg_op = 'DELETE' then
    raise exception
      'admin.audit_log is append-only: DELETE is forbidden (decision OPEN-B #3)'
      using errcode = 'check_violation';
  end if;
  return null;
end;
$$;

comment on function admin.reject_audit_mutation() is
  'Append-only backstop (decision OPEN-B #3; Axiom 5/6): rejects any UPDATE or '
  'DELETE on admin.audit_log for EVERY role, including the RLS-bypassing '
  'service role. The audit trail can only ever grow by appends.';

drop trigger if exists audit_log_reject_mutation on admin.audit_log;
create trigger audit_log_reject_mutation
  before update or delete on admin.audit_log
  for each row execute function admin.reject_audit_mutation();

-- ---------------------------------------------------------------------------
-- Row-Level Security (deny ALL client access; the backend service role reads).
--
-- Unlike notifications (a recipient self-read surface), the audit log is NEVER
-- client-readable: only an admin may read it, and that read flows through the
-- backend (service role, which BYPASSES RLS) gated by the `ListAuditLog`
-- use-case (PlatformRole.admin). So there is deliberately NO permissive policy
-- of ANY kind — with RLS enabled and no policy, every client (anon +
-- authenticated) is denied SELECT/INSERT/UPDATE/DELETE. Direct write privileges
-- are also revoked defensively (Security ADR §2 / DB ADR §10), and SELECT is
-- revoked too (no client, not even an authenticated one, reads the trail).
-- ---------------------------------------------------------------------------
alter table admin.audit_log enable row level security;

revoke select, insert, update, delete, truncate on admin.audit_log
  from anon, authenticated;

-- Explicit deny policies make the intent unmistakable (belt-and-braces atop
-- the revoked privileges): no client role reads or writes the audit log.
drop policy if exists audit_log_no_client_read on admin.audit_log;
create policy audit_log_no_client_read
  on admin.audit_log
  for select
  to anon, authenticated
  using (false);
