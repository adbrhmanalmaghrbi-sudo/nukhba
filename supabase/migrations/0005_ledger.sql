-- Migration 0005 — Ledger: turning a scored round's per-participant points into
-- the protected competitive record — an APPEND-ONLY `PointEntry` stream, with a
-- participant's balance a PROJECTION over that stream (Roadmap ADR 0008;
-- Database ADR §2.1 "key aggregates": Ledger = "append-only `PointEntry`
-- stream; balance is a projection"). Its own schema, separate from scoring.* /
-- prediction.* / competition.*: the ledger is a distinct, security-critical
-- aggregate — the asset to protect (Axiom 5).
--
-- ADRs / Axioms enforced PHYSICALLY by this migration (the database is the LAST
-- line of defence — Axiom 6; the application enforces every invariant FIRST):
--
--   * Axiom 5 (the protected asset — APPEND-ONLY, IMMUTABLE):
--     `ledger.point_entries` is append-only. There is deliberately NO in-place
--     mutation: UPDATE and DELETE are BOTH revoked from every non-owner role AND
--     rejected by an immutability trigger (`ledger.reject_entry_mutation`) that
--     fires for ANY role — including the backend service role that bypasses RLS.
--     A correction is a NEW, separate compensating entry (kind `correction`),
--     never an edit or delete of an existing row. A balance is NEVER a stored
--     mutable column: it is projected on read (a documented `SUM(amount)` query,
--     the `ledger.participant_balances` view) so it can never drift from the
--     immutable stream it summarizes.
--
--   * Axiom 2 (integrity boundary — server writes only):
--     point amounts are computed and written by the BACKEND ONLY (via the
--     service role, which BYPASSES RLS). The client can NEVER write a
--     `PointEntry`: with RLS enabled and no permissive write policy, and with
--     INSERT/UPDATE/DELETE revoked from anon + authenticated, every client write
--     is denied. A signed-in user may only READ their OWN participant's ledger.
--
--   * Axiom 4 (predict once, rank everywhere — no double-credit on replay):
--     a scored round posts EXACTLY one `round_score` credit per
--     `(participant, round)`. The unique constraint
--     `point_entries_round_score_uniq` on `(participant_id, round_id,
--     entry_kind, source_ref)` is the physical backstop: re-posting the same
--     scored round conflicts on the identical (participant, round,
--     'round_score', 'round_score:{round}:{participant}') tuple and the adapter's
--     `ON CONFLICT ON CONSTRAINT point_entries_round_score_uniq DO NOTHING`
--     skips it — never a second crediting row. A `correction` entry carries its
--     OWN distinct `source_ref`, so multiple corrections for the same
--     (participant, round) legitimately coexist (append-many) without violating
--     the same constraint.
--
--   * Axiom 6 / Database ADR §10 — the DB is the last line of defence. The
--     application enforces append-only + idempotent-post + self-read FIRST; the
--     revoked UPDATE/DELETE, the immutability trigger, the unique dedupe key, the
--     FK checks, the amount/source_ref checks, and RLS below are the BACKSTOP.
--
--   * Security ADR §2 — three trust zones; every table here is integrity
--     critical (Tier-1). Client writes are denied by default and privileges
--     revoked; a signed-in user reads only their own participant's ledger; anon
--     gets nothing.
--
--   * Database ADR — reference by id, no group reference (Axiom 4): an entry
--     names its participant and round by id only; it carries no group binding.
--
-- Forward-only, expand-only (Platform ADR). Safe to re-run: every statement is
-- guarded (`if not exists` / `create or replace` / `drop ... if exists`).
-- Reuses `identity.set_updated_at` from migration 0001.

-- ---------------------------------------------------------------------------
-- Schema
-- ---------------------------------------------------------------------------
create schema if not exists ledger;

comment on schema ledger is
  'The protected competitive record (Axiom 5) — an append-only PointEntry '
  'stream produced from scored rounds; a participant''s balance is a projection '
  'over that stream, never a stored mutable number. Separate from scoring.* / '
  'competition.*; entries are written by the backend only (Axioms 2/5) and are '
  'immutable (revoked UPDATE/DELETE + an immutability trigger — Axiom 6).';

-- ---------------------------------------------------------------------------
-- entry_kind — the closed classification of why points moved (mirrors the
-- domain EntryKind.wireValue tokens: `round_score` / `correction`). A DB enum
-- so a stored kind can never drift to an unrecognized token, and so the adapter
-- (EntryKind.tryParse) always receives one of exactly these two values.
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1
    from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where t.typname = 'entry_kind' and n.nspname = 'ledger'
  ) then
    create type ledger.entry_kind as enum ('round_score', 'correction');
  end if;
end;
$$;

comment on type ledger.entry_kind is
  'Closed classification of a ledger movement (domain EntryKind wire tokens): '
  'round_score = the credit posted for a participant''s scored round '
  '(non-negative, deduped per round); correction = a compensating adjustment '
  '(may be negative, append-many, its own distinct source_ref).';

-- ---------------------------------------------------------------------------
-- point_entries — the append-only stream (the aggregate root of the Ledger).
-- One row is one immutable movement. References participant + round by id only;
-- carries NO group reference (Axiom 4). `amount` is the signed movement,
-- server-computed only (Axioms 2/5). `source_ref` is the provenance handle
-- (never empty) that also makes the dedupe key meaningful.
--
-- The FK constraints are named EXPLICITLY (point_entries_participant_id_fkey /
-- point_entries_round_id_fkey) because the infrastructure adapter reclassifies a
-- 23503 violation into a domain error by the violated constraint name
-- (ledger.participant_not_found / ledger.round_not_found). The unique dedupe
-- constraint is named point_entries_round_score_uniq for the adapter's
-- `ON CONFLICT ON CONSTRAINT` clause and its 23505 reclassification.
-- ---------------------------------------------------------------------------
create table if not exists ledger.point_entries (
  -- The entry's own stable identity (canonical UUID = domain PointEntryId).
  id             uuid primary key,
  -- The owning participant (Competition aggregate). on delete restrict: a
  -- participant with a competitive record can NEVER be silently removed — the
  -- ledger is the protected asset (Axiom 5); its rows pin the participant.
  participant_id uuid not null
                 constraint point_entries_participant_id_fkey
                   references competition.participants (id) on delete restrict,
  -- The round this movement derives from (Competition aggregate). on delete
  -- restrict for the same reason: a round with posted ledger entries is pinned.
  round_id       uuid not null
                 constraint point_entries_round_id_fkey
                   references competition.rounds (id) on delete restrict,
  -- Why the points moved — the closed enum (mirrors domain EntryKind).
  entry_kind     ledger.entry_kind not null,
  -- The signed point movement. A `round_score` credit is non-negative (mirrors
  -- RoundScore.totalPoints); a `correction` may be negative. Server-computed
  -- only (Axioms 2/5).
  amount         integer not null,
  -- Provenance: the originating round_score handle
  -- (`round_score:{round}:{participant}`) for a credit, or the correction's
  -- justification reference. Never empty (mirrors the domain create() check).
  -- Participates in the dedupe key so a credit dedupes per round while a
  -- correction (distinct source_ref) is append-many.
  source_ref     text not null,
  -- When the movement occurred (UTC), for stream ordering + audit.
  occurred_at    timestamptz not null,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  -- A `round_score` credit must be non-negative — the DB backstop for the
  -- domain PointEntry.create() rule (Axiom 6). A negative credit would corrupt
  -- the competitive record. A `correction` is exempt (it compensates). A
  -- violation raises 23514, which the adapter maps to
  -- ledger.integrity_violation.
  constraint point_entries_round_score_nonneg
    check (entry_kind <> 'round_score' or amount >= 0),
  -- Provenance is mandatory (the domain requires a non-empty source_ref).
  constraint point_entries_source_ref_nonempty
    check (length(source_ref) > 0),
  -- The append-only dedupe key (Axiom 4): EXACTLY one entry per
  -- (participant, round, kind, source_ref). For a `round_score` credit the
  -- source_ref is deterministic (`round_score:{round}:{participant}`), so a
  -- re-post conflicts and the adapter's ON CONFLICT DO NOTHING skips it —
  -- never a second credit. A `correction` carries its own distinct source_ref,
  -- so multiple corrections for the same (participant, round) coexist
  -- (append-many). Referenced by name in the adapter's
  -- `ON CONFLICT ON CONSTRAINT point_entries_round_score_uniq`.
  constraint point_entries_round_score_uniq
    unique (participant_id, round_id, entry_kind, source_ref)
);

comment on table ledger.point_entries is
  'The append-only PointEntry stream (Axiom 5) — the protected competitive '
  'record. One immutable row per movement; participant + round by id only, no '
  'group reference (Axiom 4). amount is server-computed (Axioms 2/5). Rows are '
  'NEVER updated or deleted (revoked privileges + immutability trigger — Axiom '
  '6); a correction is a new compensating entry. Balance is projected, never '
  'stored.';

comment on column ledger.point_entries.source_ref is
  'Provenance handle (never empty). For a round_score credit it is the '
  'deterministic round_score:{round}:{participant} so a re-post dedupes; for a '
  'correction it is a distinct justification reference so corrections are '
  'append-many.';

-- Read paths: a participant's own stream (occurred_at ASC, then id — the
-- adapter's listEntries ORDER BY) and the round-posting/audit index.
create index if not exists point_entries_participant_stream_idx
  on ledger.point_entries (participant_id, occurred_at, id);
create index if not exists point_entries_round_idx
  on ledger.point_entries (round_id);

-- updated_at maintenance (backstop, Axiom 6): reuse the shared setter from
-- migration 0001. It only ever runs on the immutability-trigger-permitted path
-- (there is none for a client; the setter exists for completeness/consistency
-- with the other tables, since UPDATE is rejected outright below).
drop trigger if exists point_entries_set_updated_at
  on ledger.point_entries;
create trigger point_entries_set_updated_at
  before update on ledger.point_entries
  for each row execute function identity.set_updated_at();

-- ---------------------------------------------------------------------------
-- IMMUTABILITY trigger (Axiom 5, the strongest backstop — Axiom 6). The ledger
-- is append-only: no row may EVER be updated or deleted, by ANY role, including
-- the backend service role that bypasses RLS. RLS + privilege revocation stop
-- the client; this trigger stops even a buggy or compromised backend, so the
-- protected competitive record can only ever grow by appends. A correction is a
-- new INSERT of kind `correction`, never a mutation of an existing entry.
--
-- Raised as a check_violation so a violation the adapter ever sees maps to
-- ledger.integrity_violation (the application never issues UPDATE/DELETE, so in
-- practice this never fires from our code — it is the last line of defence).
-- ---------------------------------------------------------------------------
create or replace function ledger.reject_entry_mutation()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'UPDATE' then
    raise exception
      'ledger.point_entries is append-only: UPDATE is forbidden (Axiom 5)'
      using errcode = 'check_violation';
  elsif tg_op = 'DELETE' then
    raise exception
      'ledger.point_entries is append-only: DELETE is forbidden (Axiom 5)'
      using errcode = 'check_violation';
  end if;
  return null;
end;
$$;

comment on function ledger.reject_entry_mutation() is
  'Append-only backstop (Axiom 5/6): rejects any UPDATE or DELETE on '
  'ledger.point_entries for EVERY role, including the RLS-bypassing service '
  'role. The ledger can only ever grow by appends; a correction is a new entry.';

-- NOTE: the updated_at trigger above is `before update`; this rejection trigger
-- is also `before update`/`before delete`. Postgres fires BEFORE triggers in
-- name order — but since this one RAISES, the transaction aborts regardless of
-- ordering, so no UPDATE can ever complete. DELETE has no other before-trigger.
drop trigger if exists point_entries_reject_mutation
  on ledger.point_entries;
create trigger point_entries_reject_mutation
  before update or delete on ledger.point_entries
  for each row execute function ledger.reject_entry_mutation();

-- ---------------------------------------------------------------------------
-- participant_balances — a projection VIEW, never a stored mutable total
-- (Axiom 5; Database ADR "balance is a projection"). The balance is the signed
-- SUM over a participant's append-only stream; entry_count is how many
-- immutable movements it sums (audit). Its value is exactly the domain
-- LedgerBalance.project over the same stream. Only participants with at least
-- one entry appear; a participant with none projects a zero balance (the
-- application's LedgerBalance.project returns zero for an empty stream — the
-- adapter computes balance by reducing listEntries, so the view is a
-- documented/queryable mirror, not the source the adapter reads).
-- ---------------------------------------------------------------------------
create or replace view ledger.participant_balances as
  select
    participant_id,
    coalesce(sum(amount), 0)::bigint as balance,
    count(*)::bigint                 as entry_count
  from ledger.point_entries
  group by participant_id;

comment on view ledger.participant_balances is
  'Projection of each participant''s balance over the append-only PointEntry '
  'stream (Axiom 5: balance is a projection, never a stored number). balance = '
  'signed SUM(amount); entry_count = number of immutable movements summed. '
  'Equals the domain LedgerBalance.project over the same stream.';

-- ---------------------------------------------------------------------------
-- Row-Level Security (Tier-1: deny ALL client writes; allow only self-read).
--
-- The backend uses the service role, which BYPASSES RLS entirely — so these
-- policies constrain ONLY the client-facing (anon / authenticated) surface.
-- There is deliberately NO insert/update/delete policy: with RLS enabled and no
-- permissive write policy, all client writes are denied. Write privileges are
-- additionally revoked so a future mis-added policy cannot silently grant
-- writes (permission revocation as the last line, Security ADR §2 / Database
-- ADR §10). Even the backstop trigger forbids UPDATE/DELETE for every role.
-- ---------------------------------------------------------------------------
alter table ledger.point_entries enable row level security;

revoke insert, update, delete, truncate
  on ledger.point_entries
  from anon, authenticated;

grant select on ledger.point_entries to authenticated;

-- A signed-in user may read a point entry ONLY when it belongs to a participant
-- they OWN (self-read — the ledger is a participant's personal competitive
-- record; Security ADR §2, mirroring the ReadParticipantLedger use-case's
-- ownership gate). "Own" is resolved by joining the entry's participant to the
-- caller's platform user id. A foreign participant's entries are invisible (no
-- enumeration oracle).
drop policy if exists point_entries_select_own
  on ledger.point_entries;
create policy point_entries_select_own
  on ledger.point_entries
  for select
  to authenticated
  using (
    exists (
      select 1
      from competition.participants pa
      where pa.id = point_entries.participant_id
        and pa.user_id = auth.uid()
    )
  );

-- Anonymous callers get nothing from the ledger.
drop policy if exists point_entries_anon_no_access
  on ledger.point_entries;
create policy point_entries_anon_no_access
  on ledger.point_entries for select to anon using (false);

-- The balance projection VIEW inherits the base table's RLS (views run with the
-- querying role's privileges under security_invoker; on PG15+ we set it
-- explicitly so a client selecting the view sees only their own balance, and
-- older servers already apply the underlying table's RLS to the view owner's
-- non-superuser role). Revoke from anon; grant select to authenticated.
do $$
begin
  if exists (
    select 1 from pg_attribute a
    join pg_class c on c.oid = a.attrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'pg_catalog' and c.relname = 'pg_class'
      and a.attname = 'reloptions'
  ) then
    -- security_invoker is supported on PostgreSQL 15+. Apply it so the view
    -- enforces the base table's self-read RLS as the querying user.
    begin
      execute 'alter view ledger.participant_balances set (security_invoker = on)';
    exception when others then
      -- Older server without security_invoker: the base-table grants/RLS still
      -- constrain the client; leave the view as-is.
      null;
    end;
  end if;
end;
$$;

revoke all on ledger.participant_balances from anon;
grant select on ledger.participant_balances to authenticated;
