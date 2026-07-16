-- Migration 0003 — Prediction aggregate: a participant's single forecast for a
-- single round (Database ADR §2.1). Deliberately its own schema, SEPARATE from
-- Competition (Database ADR §1 & §2.1): predictions are the platform's
-- highest-volume integrity-critical write, so they must never contend on the
-- Competition aggregate's tables.
--
-- ADRs / Axioms enforced physically by this migration:
--   * Database ADR §2.1 — Prediction is a scale-boundary aggregate of its own,
--     referenced to Competition by id (round_id, participant_id) only, never
--     nested inside a competition/round row.
--   * Axiom 3 (football-focused seam) — the outcome is stored as a pair of
--     non-negative goal tallies (home vs. away) per fixture; there is NO general
--     "sports outcome" abstraction. The predicted fixture is an opaque UUID
--     reference to the future Football-Data aggregate (no FK yet, mirroring
--     `competition.round_fixtures`).
--   * Axiom 4 (predict once, rank everywhere) — EXACTLY one prediction per
--     (participant, round): the unique constraint below is the physical
--     backstop for the aggregate's natural key. A prediction carries NO group
--     reference; the one row is reused across every ranking context.
--   * Axiom 2/5 (integrity boundary) — points are NEVER stored here. This
--     schema holds only the submitted intent (the forecast). Turning a
--     prediction plus a `FixtureResult` into `PointEntry`s is the server-only
--     Scoring phase; the client never writes to these tables.
--   * Axiom 6 / Database ADR §10 — the database is the LAST line of defence:
--     the application enforces "one per round", "complete forecast", and "no
--     submit after lock" first; the unique constraint, the FK checks, the
--     goal-range checks, and the "round must be open" trigger below are the
--     backstop, never the primary guard.
--   * Security ADR §2 — three trust zones. The backend uses the service role
--     and BYPASSES RLS (it bears full invariant responsibility). Every table
--     here is integrity-critical (Tier-1): a signed-in user may READ ONLY their
--     own prediction (and, once the round is locked, the round's predictions),
--     and may NEVER write. Writes are denied by default and privileges revoked.
--
-- Forward-only, expand-only (Platform ADR). Safe to re-run: every statement is
-- guarded (`if not exists` / `create or replace` / `drop ... if exists`).

-- ---------------------------------------------------------------------------
-- Schema
-- ---------------------------------------------------------------------------
create schema if not exists prediction;

comment on schema prediction is
  'Prediction aggregate (Database ADR §2.1) — a participant''s single forecast '
  'per round. Separate from competition.* so high-volume prediction writes '
  'never lock the Competition aggregate.';

-- ---------------------------------------------------------------------------
-- predictions — the aggregate root. One row per (participant, round): the
-- physical "predict once" backstop (Axiom 4). References the round and the
-- participant by id only (Database ADR §2.1); carries NO group reference.
-- ---------------------------------------------------------------------------
create table if not exists prediction.predictions (
  id             uuid primary key,
  round_id       uuid not null
                 references competition.rounds (id) on delete restrict,
  -- The forecasting participant (Competition aggregate). on delete restrict:
  -- a participant with a competitive record cannot be silently removed
  -- (Axiom 5; ledger entries will pin the prediction in later phases).
  participant_id uuid not null
                 references competition.participants (id) on delete restrict,
  submitted_at   timestamptz not null,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  -- EXACTLY one prediction per (participant, round) — the aggregate's natural
  -- key (Axiom 4). Backstop for SubmitPrediction's idempotency; a concurrent
  -- duplicate insert surfaces to the adapter as prediction.already_submitted.
  constraint predictions_participant_round_uniq unique (participant_id, round_id)
);

comment on table prediction.predictions is
  'A participant''s single forecast for a round (Database ADR §2.1). One row '
  'per (participant, round) — Axiom 4 "predict once". No points here (Axioms '
  '2/5); scoring is a later server-only phase. No group reference (the one '
  'prediction is reused across every ranking context).';

create index if not exists predictions_round_idx
  on prediction.predictions (round_id);
create index if not exists predictions_participant_idx
  on prediction.predictions (participant_id);

-- ---------------------------------------------------------------------------
-- prediction_scores — one predicted scoreline per fixture in the forecast
-- (Axiom 3: the football seam). A child of the predictions root, within the
-- aggregate boundary. Deleted-and-rewritten on amendment (the parent row and
-- its identity are preserved — Axiom 4).
-- ---------------------------------------------------------------------------
create table if not exists prediction.prediction_scores (
  prediction_id uuid not null
                references prediction.predictions (id) on delete cascade,
  -- Opaque reference to the future Football-Data `Fixture` aggregate. NO FK yet
  -- (that table is a later phase); NO competition awareness on the fixture side
  -- (Axiom 3), exactly like competition.round_fixtures.fixture_id.
  fixture_id    uuid not null,
  home_goals    integer not null,
  away_goals    integer not null,
  display_order integer not null,
  -- Non-negative goal tallies within a sane ceiling — the DB backstop for the
  -- domain FixtureScorePrediction range check (Axiom 6). 99 mirrors
  -- FixtureScorePrediction.maxGoals; no real scoreline approaches it.
  constraint prediction_scores_home_range
    check (home_goals >= 0 and home_goals <= 99),
  constraint prediction_scores_away_range
    check (away_goals >= 0 and away_goals <= 99),
  constraint prediction_scores_order_nonneg check (display_order >= 0),
  -- A fixture is predicted at most once within a forecast (natural key) — the
  -- domain's no-duplicate-fixture invariant made physical (Axiom 6).
  constraint prediction_scores_pkey primary key (prediction_id, fixture_id)
);

comment on table prediction.prediction_scores is
  'One predicted scoreline per fixture in a forecast (Axiom 3, the football '
  'seam). Child of prediction.predictions; cascades on parent delete. '
  'fixture_id is an opaque reference to Football Data (no FK yet). No points '
  'here (Axioms 2/5).';

create index if not exists prediction_scores_fixture_idx
  on prediction.prediction_scores (fixture_id);

-- ---------------------------------------------------------------------------
-- updated_at maintenance (backstop, Axiom 6): reuse the shared setter defined
-- in migration 0001. The application also sets submitted_at; this trigger keeps
-- updated_at honest. `identity.set_updated_at` is schema-qualified and reusable.
-- ---------------------------------------------------------------------------
drop trigger if exists predictions_set_updated_at
  on prediction.predictions;
create trigger predictions_set_updated_at
  before update on prediction.predictions
  for each row execute function identity.set_updated_at();

-- ---------------------------------------------------------------------------
-- "No write after lock" backstop (Axiom 6): the application rejects a
-- submit/amend once the round leaves `open` (Prediction.submit/amend guard,
-- and SubmitPrediction's status check). This trigger is the database's
-- guarantee that even a rogue or buggy writer can NEVER insert or amend a
-- prediction against a non-open round: any INSERT or an UPDATE that touches the
-- forecast (via submitted_at) is rejected unless the referenced round is open.
-- Raised as a check_violation so the adapter maps it to prediction.round_not_open.
-- ---------------------------------------------------------------------------
create or replace function prediction.reject_write_after_lock()
returns trigger
language plpgsql
as $$
declare
  round_state competition.round_status;
begin
  select status into round_state
  from competition.rounds
  where id = new.round_id;

  if round_state is distinct from 'open' then
    raise exception
      'predictions can only be written while the round is open '
      '(round % is %)',
      new.round_id, coalesce(round_state::text, 'missing')
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

drop trigger if exists predictions_reject_write_after_lock
  on prediction.predictions;
create trigger predictions_reject_write_after_lock
  before insert or update on prediction.predictions
  for each row execute function prediction.reject_write_after_lock();

-- ---------------------------------------------------------------------------
-- Row-Level Security (Tier-1: deny client writes; allow narrow client reads).
--
-- The backend uses the service role, which BYPASSES RLS entirely — so these
-- policies constrain ONLY the client-facing (anon / authenticated) surface.
-- There is deliberately NO insert/update/delete policy for either table:
-- with RLS enabled and no permissive write policy, all client writes are
-- denied. Write privileges are additionally revoked so a future mis-added
-- policy cannot silently grant writes (permission revocation as the last line,
-- Security ADR §2 / Database ADR §10).
-- ---------------------------------------------------------------------------
alter table prediction.predictions       enable row level security;
alter table prediction.prediction_scores enable row level security;

revoke insert, update, delete, truncate
  on prediction.predictions, prediction.prediction_scores
  from anon, authenticated;

grant select
  on prediction.predictions, prediction.prediction_scores
  to authenticated;

-- A signed-in user may read a prediction ONLY when it is their own, OR when the
-- round is locked/scored (Axiom 2: an open round's predictions stay private so
-- no participant can copy another's forecast; once the round locks, the field
-- of predictions becomes comparable). "Own" is resolved by joining the
-- prediction's participant to the caller's platform user id.
drop policy if exists predictions_select_own_or_locked
  on prediction.predictions;
create policy predictions_select_own_or_locked
  on prediction.predictions
  for select
  to authenticated
  using (
    exists (
      select 1
      from competition.participants pa
      where pa.id = predictions.participant_id
        and pa.user_id = auth.uid()
    )
    or exists (
      select 1
      from competition.rounds r
      where r.id = predictions.round_id
        and r.status in ('locked', 'scored')
    )
  );

-- Scores follow their parent prediction's visibility (own, or locked round).
drop policy if exists prediction_scores_select_follows_parent
  on prediction.prediction_scores;
create policy prediction_scores_select_follows_parent
  on prediction.prediction_scores
  for select
  to authenticated
  using (
    exists (
      select 1
      from prediction.predictions p
      join competition.participants pa on pa.id = p.participant_id
      where p.id = prediction_scores.prediction_id
        and pa.user_id = auth.uid()
    )
    or exists (
      select 1
      from prediction.predictions p
      join competition.rounds r on r.id = p.round_id
      where p.id = prediction_scores.prediction_id
        and r.status in ('locked', 'scored')
    )
  );

-- Anonymous callers get nothing from any prediction table.
drop policy if exists predictions_anon_no_access
  on prediction.predictions;
create policy predictions_anon_no_access
  on prediction.predictions for select to anon using (false);

drop policy if exists prediction_scores_anon_no_access
  on prediction.prediction_scores;
create policy prediction_scores_anon_no_access
  on prediction.prediction_scores for select to anon using (false);
