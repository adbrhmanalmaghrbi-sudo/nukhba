-- Migration 0006 — Leaderboards: a season's ranked standings as a READ-SIDE
-- PROJECTION over the ratified append-only ledger (Roadmap ADR 0008; Axiom 5:
-- the leaderboard is a projection, NEVER a second source of truth for points;
-- Database ADR "balance is a projection"). This migration adds ONLY a
-- read-side projection VIEW plus a supporting index — deliberately NO new
-- writable table and NO second points source (Leaderboards architecture
-- decision in project-context §2).
--
-- ADRs / Axioms enforced PHYSICALLY / honoured by this migration:
--
--   * Axiom 5 (single protected truth for points): a participant's leaderboard
--     total is the signed SUM of their `ledger.point_entries.amount` (which
--     already nets in any `correction`), so the board can NEVER disagree with
--     the balance a participant reads at `GET /participants/{id}/balance`. There
--     is no stored/materialized ranking table that could drift — the standings
--     are aggregated on read from the append-only stream. Ranks themselves are
--     NOT computed here: the VIEW supplies per-participant TOTALS only; the pure
--     domain `SeasonLeaderboard.rank` assigns the ordering + standard-competition
--     ("1224") ranks, so the ranking rule is framework-free and identical
--     whoever runs the query.
--
--   * Axiom 4 (predict once, rank everywhere; no group reference): the season
--     is the first, canonical ranking context (Participant is keyed on the
--     season — Database ADR §1). The projection carries NO group binding; a
--     later Groups/Social phase reuses the identical shape over a different
--     participant set without introducing a new points source.
--
--   * Completeness (every enrolled participant appears): the VIEW is anchored on
--     `competition.participants` and LEFT JOINs the ledger, so an ACTIVE OR
--     WITHDRAWN participant with no ledger movements yet still appears with a
--     ZERO total and zero count ("enrolled, not yet credited") — the board is
--     complete from round 1. A WITHDRAWN participant is retained (Axiom 5: the
--     competitive record is never erased).
--
--   * Season scoping: a participant's ledger entries are summed ONLY over rounds
--     that belong to that participant's own season (the ledger → round → season
--     join), so points from another season's rounds can never leak into this
--     season's totals.
--
--   * Security ADR §2 / Database ADR §10 — the DB is the last line of defence.
--     The application enforces the season-membership visibility gate FIRST
--     (`GetSeasonLeaderboard` refuses a non-member `leaderboard.not_a_participant`);
--     the VIEW inherits the base tables' RLS (self-read only on participants /
--     ledger under `security_invoker`), so a client selecting the VIEW directly
--     can only ever see rows for participants/entries their own RLS permits.
--     The backend (service role) bypasses RLS and reads the full board.
--
-- Forward-only, expand-only (Platform ADR). Safe to re-run: every statement is
-- guarded (`create schema if not exists` / `create or replace view` /
-- `create index if not exists`). Reuses the tables from migrations 0002/0005;
-- introduces no new writable table, enum, trigger, or points source.

-- ---------------------------------------------------------------------------
-- Schema
-- ---------------------------------------------------------------------------
create schema if not exists leaderboard;

comment on schema leaderboard is
  'Read-side projection over the append-only Ledger (Axiom 5): season standings '
  'aggregated on read. Holds NO writable table and NO second points source — '
  'only a projection VIEW whose totals equal the participant balances. Ranks are '
  'assigned by the pure domain, not stored here.';

-- ---------------------------------------------------------------------------
-- season_standings — the season-scoped projection VIEW.
--
-- One row per season participant (ACTIVE or WITHDRAWN — a withdrawn member keeps
-- their competitive record). Columns match exactly what
-- `PostgresLeaderboardRepository.seasonStandings` selects:
--   season_id       — the participant's season (the query filters on it).
--   participant_id  — the entry's owner (by id only; no group ref — Axiom 4).
--   total_points    — signed SUM(amount) of that participant's ledger entries
--                     within the season (corrections already netted — Axiom 5);
--                     0 for an enrolled-but-never-credited participant.
--   entry_count     — number of immutable ledger movements summed (audit); 0
--                     when never credited.
--   joined_at       — the participant's UTC join instant, the domain tie-break
--                     key (earlier joiner ranks first among equal totals).
--
-- Anchored on `competition.participants` and LEFT-joined to the ledger so a
-- never-credited participant is preserved with a zero total. The ledger entries
-- are constrained to rounds of the SAME season (join `rounds` on the entry's
-- round_id and require `rounds.season_id = p.season_id`), so cross-season points
-- can never be summed in. NO ORDER BY: ordering + ranks are the domain's job
-- (`SeasonLeaderboard.rank`), realized in exactly one place.
--
-- `coalesce(..., 0)` makes the never-credited zero explicit; `::bigint` matches
-- the adapter's BigInt-tolerant `_readInt`. The GROUP BY is over the anchor
-- participant's stable columns so each participant yields exactly one row even
-- with zero matched ledger rows.
-- ---------------------------------------------------------------------------
create or replace view leaderboard.season_standings as
  select
    p.season_id                          as season_id,
    p.id                                 as participant_id,
    coalesce(sum(e.amount), 0)::bigint   as total_points,
    count(e.id)::bigint                  as entry_count,
    p.joined_at                          as joined_at
  from competition.participants p
  left join ledger.point_entries e
    on e.participant_id = p.id
   and e.round_id in (
         select r.id
         from competition.rounds r
         where r.season_id = p.season_id
       )
  group by p.season_id, p.id, p.joined_at;

comment on view leaderboard.season_standings is
  'Season standings projection (Axiom 5: a read-side projection over the '
  'append-only ledger, never a second points source). One row per season '
  'participant (ACTIVE or WITHDRAWN); total_points = signed SUM(amount) of that '
  'participant''s ledger entries within the season (corrections netted in, equal '
  'to their balance), entry_count = movements summed, 0/0 for enrolled-not-yet-'
  'credited. joined_at is the domain tie-break key. Ranks are assigned by the '
  'pure domain SeasonLeaderboard.rank, NOT stored here.';

-- ---------------------------------------------------------------------------
-- Supporting index. The VIEW's per-season aggregation groups a participant's
-- ledger entries scoped to that season's rounds; the ledger read is by
-- `(participant_id, round_id)`. Migration 0005 already indexes
-- `point_entries (participant_id, occurred_at, id)` and `(round_id)`; add a
-- composite `(participant_id, round_id)` so the season-scoped SUM/COUNT join is
-- served directly (the exact (participant, round) predicate the VIEW joins on),
-- without scanning a participant's whole stream. `if not exists` = re-runnable.
-- ---------------------------------------------------------------------------
create index if not exists point_entries_participant_round_idx
  on ledger.point_entries (participant_id, round_id);

-- ---------------------------------------------------------------------------
-- Row-Level Security. The VIEW reads `competition.participants` (self-read RLS
-- from 0002: `user_id = auth.uid()`) and `ledger.point_entries` (self-read RLS
-- from 0005). Under `security_invoker` the VIEW enforces those base-table
-- policies as the querying role, so a client selecting the VIEW directly sees
-- only their own participant row + their own summed entries (never another
-- participant's total — no enumeration oracle). The backend service role
-- bypasses RLS and reads the whole board; the application's
-- season-membership gate (`GetSeasonLeaderboard`) is the primary control, this
-- is the backstop (Axiom 6). Grant select to authenticated; deny anon.
-- ---------------------------------------------------------------------------
do $$
begin
  -- security_invoker is supported on PostgreSQL 15+. Apply it so the view
  -- enforces the base tables' self-read RLS as the querying user. Older servers
  -- already apply the underlying tables' RLS to the view owner's non-superuser
  -- role, so the client surface stays constrained either way.
  begin
    execute
      'alter view leaderboard.season_standings set (security_invoker = on)';
  exception when others then
    null;
  end;
end;
$$;

revoke all on leaderboard.season_standings from anon;
grant select on leaderboard.season_standings to authenticated;
