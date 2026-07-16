-- Migration 0002 — Competition aggregate: the structural spine of the platform
-- (root Competition -> CompetitionSeason -> Round, with RoundFixture links and
-- each round's write-once frozen ruleset snapshot) plus the separate
-- Participant aggregate.
--
-- ADRs / Axioms enforced physically by this migration:
--   * Database ADR §3 — aggregate shape: `Competition` -> `CompetitionSeason`
--     -> `Round`; `RoundFixture` is the M:N link; the round carries the
--     write-once `ruleset_snapshot`.
--   * Database ADR §1 / Axiom 4 — `Participant` is a SEPARATE aggregate keyed
--     on the season (the scale boundary: high-volume prediction/ledger writes
--     must never lock the Competition aggregate). It lives in its own table,
--     referenced by season + platform user, never nested inside a season row.
--   * Axiom 3 (football-focused seam) — a fixture carries NO competition
--     reference. Competition names a fixture ONLY through `round_fixtures`
--     (`fixture_id` is an opaque UUID reference to the future Football-Data
--     aggregate; there is deliberately no FK to a fixtures table yet — that
--     table is a later phase, and adding the FK then is a forward-only,
--     expand-only change).
--   * Axiom 4 (predict once, rank everywhere) — a `Round` carries NO group
--     reference; ranking contexts reuse one prediction. Groups are a later
--     phase, so there is no group column here.
--   * Axiom 6 / Database ADR §10 — the database is the LAST line of defence:
--     the application enforces every invariant first; the constraints, the
--     ruleset-freeze trigger, and the RLS/permission revocation below are the
--     backstop, never the primary guard.
--   * Security ADR §2 — three trust zones. The backend uses the service role
--     and BYPASSES RLS (it bears full invariant responsibility). Every table
--     here is integrity-critical (Tier-1): the client-facing surface may only
--     READ (public competitions / a caller's own participant row) and may
--     NEVER write. Writes are denied by default and privileges revoked.
--
-- Forward-only, expand-only (Platform ADR). Safe to re-run: every statement is
-- guarded (`if not exists` / `create or replace` / `drop ... if exists`).

-- ---------------------------------------------------------------------------
-- Schema
-- ---------------------------------------------------------------------------
create schema if not exists competition;

comment on schema competition is
  'Competition aggregate (Database ADR §3): the structural spine — '
  'competitions, seasons, rounds, round-fixture links, and the separate '
  'Participant aggregate. No scoring math (Scoring context) and no point '
  'balances (Ledger context) live here.';

-- ---------------------------------------------------------------------------
-- Enumerated domains (closed sets — an unknown value is a schema violation,
-- mirroring the closed domain enums: FormatType, CompetitionVisibility,
-- RoundStatus, ParticipantStatus). Wire tokens match the domain `wireValue`s
-- exactly so the adapter stores and reads the same strings the domain parses.
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where t.typname = 'format_type' and n.nspname = 'competition'
  ) then
    -- Only the founding football format exists today (Application ADR §2.10);
    -- the enum is the extension seam. Adding a value later is expand-only.
    create type competition.format_type as enum ('football_scoreline');
  end if;

  if not exists (
    select 1 from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where t.typname = 'visibility' and n.nspname = 'competition'
  ) then
    create type competition.visibility as enum ('public', 'private');
  end if;

  if not exists (
    select 1 from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where t.typname = 'round_status' and n.nspname = 'competition'
  ) then
    create type competition.round_status
      as enum ('open', 'locked', 'scored');
  end if;

  if not exists (
    select 1 from pg_type t
    join pg_namespace n on n.oid = t.typnamespace
    where t.typname = 'participant_status' and n.nspname = 'competition'
  ) then
    create type competition.participant_status
      as enum ('active', 'withdrawn');
  end if;
end
$$;

-- ---------------------------------------------------------------------------
-- competitions — the aggregate root
-- ---------------------------------------------------------------------------
create table if not exists competition.competitions (
  id         uuid primary key,
  name       text not null,
  format     competition.format_type not null,
  visibility competition.visibility  not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- Backstop for the domain's 1..120 trimmed-length rule (Competition.create).
  constraint competitions_name_len
    check (char_length(btrim(name)) between 1 and 120)
);

comment on table competition.competitions is
  'Competition aggregate root (Database ADR §3). Declares the game format '
  '(Game-Engine seam key) and who may join (visibility); hosts seasons over '
  'time. Holds no scoring or balances.';
comment on column competition.competitions.format is
  'Immutable game-format discriminator; resolves the Game Engine for rounds '
  '(Application ADR §2.10). Changing it is a new competition, not a mutation.';

-- ---------------------------------------------------------------------------
-- seasons — belongs to exactly one competition
-- ---------------------------------------------------------------------------
create table if not exists competition.seasons (
  id             uuid primary key,
  competition_id uuid not null
                 references competition.competitions (id) on delete restrict,
  label          text not null,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint seasons_label_len
    check (char_length(btrim(label)) between 1 and 60)
);

comment on table competition.seasons is
  'A season of a competition (Database ADR §3). The scope a Participant joins '
  'and the partition key for high-volume tables (predictions, ledger). '
  'on delete restrict: a competition with seasons cannot be deleted out from '
  'under them (competitive record is an asset, Axiom 5).';

create index if not exists seasons_competition_idx
  on competition.seasons (competition_id);

-- ---------------------------------------------------------------------------
-- rounds — belongs to exactly one season; carries the write-once ruleset
-- ---------------------------------------------------------------------------
create table if not exists competition.rounds (
  id                  uuid primary key,
  season_id           uuid not null
                      references competition.seasons (id) on delete restrict,
  sequence            integer not null,
  prediction_deadline timestamptz not null,
  status              competition.round_status not null default 'open',
  -- The frozen ruleset (Database ADR §3). JSONB so the structured payload is
  -- stored verbatim; Competition never interprets it (Application ADR §2.10).
  -- Write-once is enforced by the trigger below (Axiom 6 backstop).
  ruleset_snapshot    jsonb not null,
  ruleset_version     integer not null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  -- Backstop for Round.open: 1-based ordinal, positive version, non-empty
  -- snapshot (a round must freeze *some* rules).
  constraint rounds_sequence_positive check (sequence >= 1),
  constraint rounds_ruleset_version_positive check (ruleset_version >= 1),
  constraint rounds_ruleset_snapshot_object
    check (jsonb_typeof(ruleset_snapshot) = 'object'
           and ruleset_snapshot <> '{}'::jsonb),
  -- A round's ordinal is unique within its season (Database ADR §3). This is
  -- the storage-layer backstop the repository surfaces as an invariant
  -- conflict on a duplicate sequence.
  constraint rounds_season_sequence_uniq unique (season_id, sequence)
);

comment on table competition.rounds is
  'A round within a season — the unit users predict and the carrier of the '
  'frozen ruleset (Database ADR §3). Born open with the ruleset already '
  'frozen; status advances only open -> locked -> scored.';
comment on column competition.rounds.ruleset_snapshot is
  'Write-once frozen ruleset (JSONB). Immutable once the round leaves open; '
  'enforced by trigger rounds_freeze_ruleset (Axiom 6). Structurally opaque '
  'to Competition — only the Scoring context interprets its keys.';

create index if not exists rounds_season_idx
  on competition.rounds (season_id);

-- ---------------------------------------------------------------------------
-- round_fixtures — the M:N link between a round and a Football-Data fixture
-- (Axiom 3: the ONLY place Competition names a fixture).
-- ---------------------------------------------------------------------------
create table if not exists competition.round_fixtures (
  round_id      uuid not null
                references competition.rounds (id) on delete restrict,
  -- Opaque reference to the future Football-Data `Fixture` aggregate. NO FK
  -- yet (that table is a later phase); NO competition_id on the fixture side.
  fixture_id    uuid not null,
  display_order integer not null,
  created_at    timestamptz not null default now(),
  constraint round_fixtures_order_nonneg check (display_order >= 0),
  -- A fixture is linked to a round at most once (natural key).
  constraint round_fixtures_pkey primary key (round_id, fixture_id)
);

comment on table competition.round_fixtures is
  'M:N link round <-> fixture (Database ADR §3, Axiom 3). fixture_id is an '
  'opaque reference to Football Data (no FK yet, no competition awareness on '
  'the fixture). display_order fixes matchday presentation order.';

create index if not exists round_fixtures_fixture_idx
  on competition.round_fixtures (fixture_id);

-- ---------------------------------------------------------------------------
-- participants — a SEPARATE aggregate (Database ADR §1, Axiom 4)
-- ---------------------------------------------------------------------------
create table if not exists competition.participants (
  id         uuid primary key,
  season_id  uuid not null
             references competition.seasons (id) on delete restrict,
  -- The enrolled platform user (Identity aggregate). on delete restrict:
  -- a user with a competitive record cannot be silently removed (Axiom 5;
  -- ledger entries will pin the participant in later phases).
  user_id    uuid not null
             references identity.users (id) on delete restrict,
  status     competition.participant_status not null default 'active',
  joined_at  timestamptz not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- A user joins a season at most once (Database ADR §3). Backstop for the
  -- join use-case's idempotency; surfaced as competition.already_joined.
  constraint participants_season_user_uniq unique (season_id, user_id)
);

comment on table competition.participants is
  'A user''s enrolment in a season — its own aggregate (Database ADR §1), '
  'deliberately separate from Competition so high-volume prediction writes '
  'never lock the Competition aggregate. Withdrawal never deletes the row '
  '(Axiom 5).';

create index if not exists participants_season_idx
  on competition.participants (season_id);
create index if not exists participants_user_idx
  on competition.participants (user_id);

-- ---------------------------------------------------------------------------
-- updated_at maintenance (backstop, Axiom 6): reuse the shared setter defined
-- in migration 0001. The application also sets it; the trigger is the last
-- line. `identity.set_updated_at` is schema-qualified and reusable.
-- ---------------------------------------------------------------------------
drop trigger if exists competitions_set_updated_at
  on competition.competitions;
create trigger competitions_set_updated_at
  before update on competition.competitions
  for each row execute function identity.set_updated_at();

drop trigger if exists seasons_set_updated_at on competition.seasons;
create trigger seasons_set_updated_at
  before update on competition.seasons
  for each row execute function identity.set_updated_at();

drop trigger if exists rounds_set_updated_at on competition.rounds;
create trigger rounds_set_updated_at
  before update on competition.rounds
  for each row execute function identity.set_updated_at();

drop trigger if exists participants_set_updated_at on competition.participants;
create trigger participants_set_updated_at
  before update on competition.participants
  for each row execute function identity.set_updated_at();

-- ---------------------------------------------------------------------------
-- Ruleset-freeze trigger (Axiom 6 backstop for the domain's founding
-- invariant). The application never issues an UPDATE that changes the ruleset
-- — Round has no API to replace a snapshot, and updateRoundStatus only touches
-- `status`. This trigger is the database's guarantee that even a rogue or
-- buggy writer can NEVER rewrite a frozen ruleset: any UPDATE that changes
-- `ruleset_snapshot` or `ruleset_version` is rejected outright. The snapshot is
-- therefore write-once for the life of the row — set at INSERT (round opens),
-- immutable forever after (Database ADR §3, Domain-invariants section).
-- ---------------------------------------------------------------------------
create or replace function competition.reject_ruleset_mutation()
returns trigger
language plpgsql
as $$
begin
  if new.ruleset_snapshot is distinct from old.ruleset_snapshot
     or new.ruleset_version is distinct from old.ruleset_version then
    raise exception
      'ruleset snapshot is write-once and cannot be modified (round %)',
      old.id
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

drop trigger if exists rounds_freeze_ruleset on competition.rounds;
create trigger rounds_freeze_ruleset
  before update on competition.rounds
  for each row execute function competition.reject_ruleset_mutation();

-- ---------------------------------------------------------------------------
-- Round lifecycle backstop (Axiom 6): status advances only
-- open -> locked -> scored. The application enforces this first
-- (Round.transitionTo, single definition of legal edges); this trigger rejects
-- any illegal status move that reaches the database — a backward step, a skip
-- (open -> scored), or any change out of the terminal `scored` state.
-- ---------------------------------------------------------------------------
create or replace function competition.enforce_round_lifecycle()
returns trigger
language plpgsql
as $$
begin
  if new.status = old.status then
    return new; -- non-status update (e.g. updated_at); nothing to check.
  end if;
  if not (
    (old.status = 'open'   and new.status = 'locked')
    or (old.status = 'locked' and new.status = 'scored')
  ) then
    raise exception
      'illegal round transition % -> % (round %)',
      old.status, new.status, old.id
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

drop trigger if exists rounds_enforce_lifecycle on competition.rounds;
create trigger rounds_enforce_lifecycle
  before update on competition.rounds
  for each row execute function competition.enforce_round_lifecycle();

-- ---------------------------------------------------------------------------
-- Row-Level Security (Tier-1: deny client writes; allow narrow client reads).
--
-- The backend uses the service role, which BYPASSES RLS entirely — so these
-- policies constrain ONLY the client-facing (anon / authenticated) surface.
-- There is deliberately NO insert/update/delete policy for any table here:
-- with RLS enabled and no permissive write policy, all client writes are
-- denied. Write privileges are additionally revoked so a future mis-added
-- policy cannot silently grant writes (permission revocation as the last line,
-- Security ADR §2 / Database ADR §10).
-- ---------------------------------------------------------------------------
alter table competition.competitions    enable row level security;
alter table competition.seasons         enable row level security;
alter table competition.rounds          enable row level security;
alter table competition.round_fixtures  enable row level security;
alter table competition.participants    enable row level security;

revoke insert, update, delete, truncate
  on competition.competitions, competition.seasons, competition.rounds,
     competition.round_fixtures, competition.participants
  from anon, authenticated;

grant select
  on competition.competitions, competition.seasons, competition.rounds,
     competition.round_fixtures
  to authenticated;
grant select on competition.participants to authenticated;

-- Public competitions are discoverable by any signed-in user; private ones are
-- not visible on the client surface (their audience binding arrives with the
-- Groups phase). The backend (service role) still sees everything.
drop policy if exists competitions_select_public on competition.competitions;
create policy competitions_select_public
  on competition.competitions
  for select
  to authenticated
  using (visibility = 'public');

-- Seasons/rounds/round_fixtures are readable by a signed-in user only when
-- their competition is public (join through to the visibility flag).
drop policy if exists seasons_select_public on competition.seasons;
create policy seasons_select_public
  on competition.seasons
  for select
  to authenticated
  using (
    exists (
      select 1 from competition.competitions c
      where c.id = seasons.competition_id and c.visibility = 'public'
    )
  );

drop policy if exists rounds_select_public on competition.rounds;
create policy rounds_select_public
  on competition.rounds
  for select
  to authenticated
  using (
    exists (
      select 1
      from competition.seasons s
      join competition.competitions c on c.id = s.competition_id
      where s.id = rounds.season_id and c.visibility = 'public'
    )
  );

drop policy if exists round_fixtures_select_public
  on competition.round_fixtures;
create policy round_fixtures_select_public
  on competition.round_fixtures
  for select
  to authenticated
  using (
    exists (
      select 1
      from competition.rounds r
      join competition.seasons s on s.id = r.season_id
      join competition.competitions c on c.id = s.competition_id
      where r.id = round_fixtures.round_id and c.visibility = 'public'
    )
  );

-- A signed-in user may read ONLY their own participant rows.
drop policy if exists participants_select_self on competition.participants;
create policy participants_select_self
  on competition.participants
  for select
  to authenticated
  using (user_id = auth.uid());

-- Anonymous callers get nothing from any competition table.
drop policy if exists competitions_anon_no_access
  on competition.competitions;
create policy competitions_anon_no_access
  on competition.competitions for select to anon using (false);

drop policy if exists seasons_anon_no_access on competition.seasons;
create policy seasons_anon_no_access
  on competition.seasons for select to anon using (false);

drop policy if exists rounds_anon_no_access on competition.rounds;
create policy rounds_anon_no_access
  on competition.rounds for select to anon using (false);

drop policy if exists round_fixtures_anon_no_access
  on competition.round_fixtures;
create policy round_fixtures_anon_no_access
  on competition.round_fixtures for select to anon using (false);

drop policy if exists participants_anon_no_access
  on competition.participants;
create policy participants_anon_no_access
  on competition.participants for select to anon using (false);
