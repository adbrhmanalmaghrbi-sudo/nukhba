-- Migration 0004 — Scoring: turning a stored prediction plus the fixture's
-- actual result into a participant's server-computed points for a round
-- (Roadmap ADR 0008; Database ADR §2.1). Its own schema, separate from
-- prediction.* and competition.*: scores are a distinct read model produced by
-- the server-only Scoring phase.
--
-- ADRs / Axioms enforced physically by this migration:
--   * Axiom 2/5 (integrity boundary) — points are computed and written by the
--     backend ONLY (via the service role, which BYPASSES RLS). The client can
--     never write to any table here; a signed-in user may only READ a scored
--     round's scores. The competitive record is the protected asset; turning
--     these scores into an append-only PointEntry stream is the LATER Ledger
--     phase — this schema holds only the derived per-round scores.
--   * Axiom 3 (football seam) — the actual result is stored as a pair of
--     non-negative goal tallies (home vs. away) keyed by an OPAQUE fixture id
--     (no FK to any Football-Data table — that aggregate is a later phase;
--     mirrors prediction.prediction_scores.fixture_id and
--     competition.round_fixtures.fixture_id). There is NO general "sports
--     outcome" abstraction. This is the single Axiom-3 seam (Next-Task decision
--     2026-07-11, option (a): a minimal FixtureResult, APPROVED and MANDATORY).
--   * Axiom 4 (predict once, rank everywhere) — EXACTLY one score per
--     (round, participant): the unique constraint below is the physical
--     backstop. A round score carries NO group reference; the one score is
--     ranked in every context.
--   * Axiom 6 / Database ADR §10 — the database is the LAST line of defence.
--     The application enforces "score only a locked round", idempotent replay,
--     the goal-range on ingested results, and one-score-per-participant first;
--     the check constraints, the FK checks, the unique key, and the
--     "round must be locked or scored" trigger below are the backstop.
--   * Security ADR §2 — three trust zones; every table here is integrity
--     critical (Tier-1). Client writes are denied by default and privileges
--     revoked; anon gets nothing.
--
-- Forward-only, expand-only (Platform ADR). Safe to re-run: every statement is
-- guarded (`if not exists` / `create or replace` / `drop ... if exists`).

-- ---------------------------------------------------------------------------
-- Schema
-- ---------------------------------------------------------------------------
create schema if not exists scoring;

comment on schema scoring is
  'Scoring read model (Roadmap ADR 0008) — server-computed per-round scores '
  'derived from a prediction plus the fixture''s actual result. Separate from '
  'prediction.* / competition.*; points are written by the backend only '
  '(Axioms 2/5). Turning scores into an append-only PointEntry stream is the '
  'later Ledger phase.';

-- ---------------------------------------------------------------------------
-- fixture_results — the actual final score of a fixture (Axiom 3, the single
-- football seam). One row per fixture; keyed by the opaque fixture id only —
-- NO competition/round/group reference, so the same result feeds every round
-- the fixture belongs to. Ingested by an admin command (Axiom 2: the client
-- never writes results); idempotent-correctable in place.
-- ---------------------------------------------------------------------------
create table if not exists scoring.fixture_results (
  -- Opaque reference to the future Football-Data `Fixture` aggregate. NO FK yet
  -- (that table is a later phase); NO competition awareness (Axiom 3), exactly
  -- like prediction.prediction_scores.fixture_id.
  fixture_id  uuid primary key,
  home_goals  integer not null,
  away_goals  integer not null,
  -- The ingestion instant the adapter stamps (audit); refreshed on correction.
  recorded_at timestamptz not null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  -- Non-negative goal tallies within a sane ceiling — the DB backstop for the
  -- domain FixtureResult range check (Axiom 6). 99 mirrors FixtureResult.maxGoals
  -- (identical to FixtureScorePrediction.maxGoals so a real result can always be
  -- compared against any accepted prediction). A violation raises 23514, which
  -- the adapter maps to scoring.result_integrity_violation.
  constraint fixture_results_home_range
    check (home_goals >= 0 and home_goals <= 99),
  constraint fixture_results_away_range
    check (away_goals >= 0 and away_goals <= 99)
);

comment on table scoring.fixture_results is
  'The actual final score of a fixture (Axiom 3, the football seam; Next-Task '
  'option (a)). One row per opaque fixture id; no competition/round reference. '
  'Ingested by an admin command only (Axioms 2/5).';

-- ---------------------------------------------------------------------------
-- updated_at maintenance (backstop, Axiom 6): reuse the shared setter defined
-- in migration 0001. `identity.set_updated_at` is schema-qualified and reusable.
-- ---------------------------------------------------------------------------
drop trigger if exists fixture_results_set_updated_at
  on scoring.fixture_results;
create trigger fixture_results_set_updated_at
  before update on scoring.fixture_results
  for each row execute function identity.set_updated_at();

-- ---------------------------------------------------------------------------
-- round_scores — a participant's computed score for a round (the aggregate
-- root of the Scoring read model). One row per (round, participant): the
-- physical "one score per participant per round" backstop (Axiom 4), mirroring
-- the one prediction it was computed from. References round and participant by
-- id only; carries NO group reference. Points are the derived total, written
-- by the server only (Axioms 2/5).
--
-- The FK constraints are named EXPLICITLY (round_scores_round_id_fkey /
-- round_scores_participant_id_fkey) because the infrastructure adapter
-- reclassifies a 23503 violation into a domain error by the violated
-- constraint name (scoring.round_not_found / scoring.not_a_participant).
-- ---------------------------------------------------------------------------
create table if not exists scoring.round_scores (
  round_id        uuid not null
                  constraint round_scores_round_id_fkey
                    references competition.rounds (id) on delete restrict,
  -- The scored participant (Competition aggregate). on delete restrict: a
  -- participant with a competitive record cannot be silently removed (Axiom 5;
  -- ledger entries will pin the score in later phases).
  participant_id  uuid not null
                  constraint round_scores_participant_id_fkey
                    references competition.participants (id) on delete restrict,
  -- The version of the frozen ruleset used to compute this score, so a score
  -- can always be traced to the exact rules (Axiom 5, reproducibility).
  ruleset_version integer not null,
  -- The derived sum of every fixture's points — server-computed, never client
  -- supplied (Axioms 2/5). Non-negative (awards are non-negative).
  total_points    integer not null,
  scored_at       timestamptz not null default now(),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint round_scores_total_nonneg check (total_points >= 0),
  constraint round_scores_ruleset_version_pos check (ruleset_version >= 1),
  -- EXACTLY one score per (round, participant) — the aggregate's natural key
  -- (Axiom 4). Backstop for the scoring use-case's idempotent replay; the
  -- adapter's ON CONFLICT (round_id, participant_id) refreshes in place.
  constraint round_scores_round_participant_uniq
    unique (round_id, participant_id)
);

comment on table scoring.round_scores is
  'A participant''s computed score for a round (Scoring read model). One row '
  'per (round, participant) — Axiom 4. Points are server-computed (Axioms '
  '2/5); no group reference; ruleset_version pins the frozen rules used.';

create index if not exists round_scores_round_idx
  on scoring.round_scores (round_id);
create index if not exists round_scores_participant_idx
  on scoring.round_scores (participant_id);

drop trigger if exists round_scores_set_updated_at
  on scoring.round_scores;
create trigger round_scores_set_updated_at
  before update on scoring.round_scores
  for each row execute function identity.set_updated_at();

-- ---------------------------------------------------------------------------
-- round_score_fixtures — the per-fixture breakdown of a round score (grade +
-- points), in the prediction's fixture order. A child of round_scores within
-- the aggregate boundary; deleted-and-rewritten on re-score (the parent row is
-- upserted in place — Axiom 4). Keyed on (round_id, participant_id) to the
-- parent so the adapter can delete+reinsert atomically inside one transaction.
--
-- The FK constraints are named EXPLICITLY (round_score_fixtures_round_id_fkey /
-- round_score_fixtures_participant_id_fkey) so the adapter's 23503
-- reclassification matches by constraint name.
-- ---------------------------------------------------------------------------
create table if not exists scoring.round_score_fixtures (
  round_id       uuid not null
                 constraint round_score_fixtures_round_id_fkey
                   references competition.rounds (id) on delete restrict,
  participant_id uuid not null
                 constraint round_score_fixtures_participant_id_fkey
                   references competition.participants (id) on delete restrict,
  -- Opaque reference to Football Data (no FK — Axiom 3), same as the prediction
  -- and result tables.
  fixture_id     uuid not null,
  -- The closed, ordered grade classification (Axiom 3): the stable wire tokens
  -- of the domain FixtureScoreGrade enum. A DB backstop constrains it to the
  -- exact three tokens the adapter emits/parses.
  grade          text not null,
  -- Points awarded for this fixture under the round's frozen ruleset
  -- (non-negative; server-computed — Axioms 2/5).
  points         integer not null,
  display_order  integer not null,
  constraint round_score_fixtures_points_nonneg check (points >= 0),
  constraint round_score_fixtures_order_nonneg check (display_order >= 0),
  constraint round_score_fixtures_grade_valid
    check (grade in ('exact_scoreline', 'correct_outcome', 'incorrect')),
  -- A fixture is graded at most once within a participant's round score
  -- (natural key) — the domain's no-duplicate-fixture invariant made physical
  -- (Axiom 6).
  constraint round_score_fixtures_pkey
    primary key (round_id, participant_id, fixture_id),
  -- Bind the child to its parent round score, so a child can never outlive its
  -- parent and the parent's natural key is honoured. Cascades on parent delete.
  constraint round_score_fixtures_parent_fkey
    foreign key (round_id, participant_id)
    references scoring.round_scores (round_id, participant_id)
    on delete cascade
);

comment on table scoring.round_score_fixtures is
  'Per-fixture grade + points of a round score (Axiom 3, the football seam). '
  'Child of scoring.round_scores; cascades on parent delete. Rewritten in '
  'place on re-score. fixture_id is opaque (no FK). Server-computed (Axioms '
  '2/5).';

create index if not exists round_score_fixtures_fixture_idx
  on scoring.round_score_fixtures (fixture_id);

-- ---------------------------------------------------------------------------
-- "Score only a locked round" backstop (Axiom 6): the application rejects
-- ScoreRound unless the round is `locked` (or already `scored`, for an
-- idempotent replay). This trigger is the database's guarantee that even a
-- rogue or buggy writer can NEVER persist a score for an `open` round: any
-- INSERT or UPDATE of a round_scores row is rejected unless the referenced
-- round is locked or scored. Raised as a check_violation so the adapter maps
-- it to scoring.integrity_violation (the application-side guard reports the
-- precise scoring.round_not_locked first).
-- ---------------------------------------------------------------------------
create or replace function scoring.reject_score_before_lock()
returns trigger
language plpgsql
as $$
declare
  round_state competition.round_status;
begin
  select status into round_state
  from competition.rounds
  where id = new.round_id;

  if round_state not in ('locked', 'scored') then
    raise exception
      'a round can only be scored once it is locked '
      '(round % is %)',
      new.round_id, coalesce(round_state::text, 'missing')
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

drop trigger if exists round_scores_reject_score_before_lock
  on scoring.round_scores;
create trigger round_scores_reject_score_before_lock
  before insert or update on scoring.round_scores
  for each row execute function scoring.reject_score_before_lock();

-- ---------------------------------------------------------------------------
-- Row-Level Security (Tier-1: deny client writes; allow narrow client reads).
--
-- The backend uses the service role, which BYPASSES RLS entirely — so these
-- policies constrain ONLY the client-facing (anon / authenticated) surface.
-- There is deliberately NO insert/update/delete policy for any table: with RLS
-- enabled and no permissive write policy, all client writes are denied. Write
-- privileges are additionally revoked so a future mis-added policy cannot
-- silently grant writes (permission revocation as the last line, Security ADR
-- §2 / Database ADR §10).
-- ---------------------------------------------------------------------------
alter table scoring.fixture_results      enable row level security;
alter table scoring.round_scores         enable row level security;
alter table scoring.round_score_fixtures enable row level security;

revoke insert, update, delete, truncate
  on scoring.fixture_results,
     scoring.round_scores,
     scoring.round_score_fixtures
  from anon, authenticated;

grant select
  on scoring.round_scores, scoring.round_score_fixtures
  to authenticated;

-- fixture_results is an admin/football-data ingestion surface, not part of the
-- participant-facing read model; the client gets NO select on it (the scored
-- breakdown a participant sees is exposed via round_score_fixtures, which
-- already carries the derived grade/points). Deny it explicitly.
drop policy if exists fixture_results_no_client_access
  on scoring.fixture_results;
create policy fixture_results_no_client_access
  on scoring.fixture_results for select
  to anon, authenticated using (false);

-- A signed-in user may read a round score ONLY when the round is `scored`
-- (Axiom 2: scores become visible once the round is fully scored) AND they are
-- a participant in that round's season (season-membership gate mirrors the
-- ListRoundPredictions/GetRoundScores application rule). "Participant" is
-- resolved by joining the round's season to the caller's platform user id.
drop policy if exists round_scores_select_scored_member
  on scoring.round_scores;
create policy round_scores_select_scored_member
  on scoring.round_scores
  for select
  to authenticated
  using (
    exists (
      select 1
      from competition.rounds r
      join competition.participants pa on pa.season_id = r.season_id
      where r.id = round_scores.round_id
        and r.status = 'scored'
        and pa.user_id = auth.uid()
    )
  );

-- Child breakdown follows its parent round score's visibility.
drop policy if exists round_score_fixtures_select_follows_parent
  on scoring.round_score_fixtures;
create policy round_score_fixtures_select_follows_parent
  on scoring.round_score_fixtures
  for select
  to authenticated
  using (
    exists (
      select 1
      from competition.rounds r
      join competition.participants pa on pa.season_id = r.season_id
      where r.id = round_score_fixtures.round_id
        and r.status = 'scored'
        and pa.user_id = auth.uid()
    )
  );

-- Anonymous callers get nothing from any scoring table.
drop policy if exists round_scores_anon_no_access
  on scoring.round_scores;
create policy round_scores_anon_no_access
  on scoring.round_scores for select to anon using (false);

drop policy if exists round_score_fixtures_anon_no_access
  on scoring.round_score_fixtures;
create policy round_score_fixtures_anon_no_access
  on scoring.round_score_fixtures for select to anon using (false);
