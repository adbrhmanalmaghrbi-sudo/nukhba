# Leaderboards Phase — Six-Way Review

_Reviewer role: auditor, by direct on-disk inspection of every Leaderboards file
across all six layers (2026-07-11). Phase-exit gate. The lower four layers
(domain / contracts / application) were delivered in prior sessions; the
infrastructure adapter, migration `0006_leaderboard.sql`, and the `apps/server`
route + mapper + CompositionRoot wiring + route tests were delivered this
session. This review verifies them together and confirms the phase is complete
end-to-end._

Result: **GREEN.** No High or Medium defect. Findings are info/low: one
comment-only doc/code mismatch (L-1) fixed in-place, and one SSoT test-count
precision note (D-1) corrected in §2/§4. No behavioural change was required.

---

## 0. Scope verified on disk

| Layer | Files (verified present & complete) |
|---|---|
| Domain | `leaderboard_entry.dart` (153 L — `LeaderboardEntry`, `projected` unranked + `withRank`, sign-free `entryCount`, UTC `joinedAt`, sentinel rank 0, value equality by all fields), `season_leaderboard.dart` (157 L — `SeasonLeaderboard.rank`: dup-reject, total order points-desc/joinedAt-asc/id-asc, standard "1224" ranks, unmodifiable entries); both exported from `domain.dart`; tests `leaderboard_entry_test.dart` (10), `season_leaderboard_test.dart` (14) |
| Contracts | `leaderboard_dto.dart` (165 L — `LeaderboardEntryDto`, `SeasonLeaderboardDto`; versioned, snake_case, order-significant equality, no group/points-write field); exported from `contracts.dart`; `leaderboard_dto_test.dart` (8) |
| Application | port `ports/leaderboard_repository.dart` (`LeaderboardRepository.seasonStandings` → unranked per-participant projection); use-case `get_season_leaderboard.dart` (`GetSeasonLeaderboard`: user-role gate → season-id parse → season-membership gate → domain rank); both exported; tests `fakes.dart`, `get_season_leaderboard_test.dart` (9) |
| Infrastructure | `postgres_leaderboard_repository.dart` (160 L — single `@season_id`-bound read over the VIEW, NO SQL ORDER BY, unranked row→`LeaderboardEntry.projected` mapping, corrupt-row→transient `leaderboard.row_corrupt`); exported from `infrastructure.dart`; `postgres_leaderboard_repository_test.dart` (7, hermetic) + `..._integration_test.dart` (DB-gated, tagged `integration`) |
| Migration | `supabase/migrations/0006_leaderboard.sql` (157 L — **this session**) |
| Server | `routes/seasons/[id]/leaderboard/index.dart`, `lib/http/leaderboard_dto_mapper.dart`; CompositionRoot wires `getSeasonLeaderboard` real (bootstrap) + `_absentGetSeasonLeaderboard`/`_UnwiredLeaderboardRepository` stand-in (forTesting); `test/routes/season_leaderboard_test.dart` (6) over `InMemoryLeaderboardRepository` added to `competition_route_harness.dart` (**this session**) |

---

## 1. Architecture

- **A leaderboard is a read-side projection, never a second points source
  (Axiom 5)** — as ratified in §2 before any code. The whole ranking chain reads
  from `ledger.point_entries` (via the VIEW) and never writes or stores a total.
  The migration adds **only** a `create or replace view` + a supporting index —
  verified statement by statement: no `create table`, no enum, no trigger, no
  second points source.
- **Ranking lives in exactly one place — the pure domain.** The adapter's SQL
  has **no `ORDER BY`** (verified: the hermetic test asserts
  `isNot(contains('ORDER BY'))`); the VIEW supplies unordered per-participant
  totals; `SeasonLeaderboard.rank` owns the total order + "1224" ranks. The
  ranking rule is therefore framework-free and identical whoever runs the query.
- **Clean-Architecture dependency rule** — `get_season_leaderboard.dart` imports
  `application` (competition port + authorization + its own port) + `domain` +
  `shared` only; `postgres_leaderboard_repository.dart` imports
  `application`/`domain`/`infrastructure(db)`/`shared`; the route + mapper import
  `application`/`domain`/`contracts`/`shared`; `CompositionRoot` remains the sole
  importer of the concrete adapter. **No new internal package** appeared (the
  `leaderboard` slice lives inside the existing four packages), so
  `tooling/import_lint` ruleset is unchanged — verified: no edit to
  `tooling/import_lint`.
- **Reference by id, no group reference (Axiom 4)** — `LeaderboardEntry` names a
  participant by id and carries no group binding; the DTOs carry no group field
  (route test asserts `entries[0].containsKey('group_id') == false`); the VIEW
  selects no group column. A later Groups/Social phase reuses the identical shape
  over a different participant set. Verified.

## 2. Security

- **Read-only surface — no write path (Axioms 2/5).** There is deliberately no
  command DTO and no non-GET handler: the route returns `405` for any method
  other than GET. The client never submits or computes a total; rank/total/count
  are all server-produced. Verified in the DTO file header and the route guard.
- **Visibility gate = season membership (Security ADR §2).** The gate lives
  entirely in `GetSeasonLeaderboard`: `Authorization.requireRole(user)` →
  `SeasonId.tryParse` → `CompetitionRepository.findParticipant(sId, userId)`; a
  non-member (or an unknown season — same path) is refused **identically** with
  `authorization` `leaderboard.not_a_participant` → `401`, so there is no
  season-existence oracle beyond membership. A withdrawn member is still a
  participant and still sees the board (verified in the application test
  `a withdrawn member may still read the board`). The route makes no authz
  decision of its own.
- **DB backstop (Axiom 6) — layered defence.** The VIEW is `security_invoker`
  (applied defensively inside a `do $$ … exception … null` block for PG15+), so a
  client selecting the VIEW directly inherits the base tables' self-read RLS
  (`competition.participants.user_id = auth.uid()` from 0002; `point_entries`
  self-read from 0005) — a client can never enumerate another participant's
  total. `revoke all … from anon; grant select … to authenticated`. The app gate
  is primary, RLS the backstop. The backend service role bypasses RLS and reads
  the whole board (as required to rank it). Verified.
- **Parameterized SQL.** The only SQL authored this phase binds `season_id`
  through a single `@named` parameter (verified: hermetic test asserts
  `parameters.single == {'season_id': …}`); the migration contains no dynamic
  user input.

## 3. Correctness

- **Total order is deterministic and total (never arbitrary DB order).**
  `SeasonLeaderboard._compare`: points DESC, then `joinedAt` ASC, then
  `participantId.value` ASC. The domain test suite covers points-desc,
  input-order-independence (determinism), earlier-joinedAt-first,
  equal-joinedAt→lower-id-first, and negative (net-correction) totals ranking
  below zero. Verified.
- **Standard competition "1224" ranks.** `rank` assigns a shared rank to equal
  consecutive totals and lets the 1-based position produce the skip. Domain tests
  assert `1,1,3` (two tied for 1st → next is 3), a three-way tie `1,1,1,4`, and a
  mid-table tie `1,2,2,4`. The route test asserts the same "1224" tie sharing
  across the HTTP boundary (two tied on 5 both show rank 2, earlier joiner
  displayed first). Verified.
- **Every enrolled participant appears; never-credited = zero row.** The VIEW is
  anchored on `competition.participants` LEFT JOIN `ledger.point_entries` with
  `coalesce(sum(amount),0)::bigint` / `count(e.id)::bigint`, so an ACTIVE or
  WITHDRAWN participant with no ledger movements appears with `0/0`. Domain +
  application + route tests each assert a zero-total participant is present and
  ranked last. Verified.
- **Empty board is a legitimate result, not an error.** A season with no
  participants yields `Ok(empty)` end-to-end (adapter → use-case → route `200`
  with empty `entries`). Verified at all three layers.
- **Season scoping — no cross-season leakage.** The VIEW sums a participant's
  ledger entries only over rounds of that participant's own season
  (`e.round_id in (select r.id from competition.rounds r where r.season_id =
  p.season_id)`), so another season's points can never be summed in. Documented
  as a CI integration scenario; structurally verified in the VIEW SQL.
- **Total equals balance (Axiom 5 — single truth).** `total_points` is the same
  signed `SUM(amount)` the participant reads at `GET /participants/{id}/balance`;
  a `correction` is already netted in. The integration test documents the
  "correction nets in" scenario CI exercises. Verified structurally (identical
  aggregation over the same append-only stream).
- **Corrupt-row safety on a read path.** A bad participant-id, non-int
  total/count, or absent/non-UTC `joined_at`, or a domain `projected()` `Err`,
  all map to a transient `leaderboard.row_corrupt` — a read path never leaks a
  raw invariant/validation. Hermetic test covers the three corrupt-row cases +
  the transient passthrough. Verified.
- **`_readInt` bigint tolerance.** `SUM`/`count` arrive as `bigint`; `_readInt`
  accepts `int` / `BigInt`(valid-int) / `String`. Hermetic test drives a
  `BigInt` total + count. Verified.

## 4. Performance

- **A single indexed read per request.** The adapter issues one `SELECT` over the
  VIEW; the VIEW's per-(participant,round) join is served by the composite index
  `point_entries_participant_round_idx (participant_id, round_id)` added this
  migration (0005 already had participant-stream + round indexes). Ranking is an
  in-memory sort of the season's participant set — bounded by season size, cheap
  at current scale.
- **Live aggregation vs. materialized table — deliberate.** As ratified, the
  board is aggregated on read rather than stored, trading a (bounded) read-time
  `SUM` for zero drift risk on the protected record and no unwired outbox. A
  future scale phase MAY materialize it, but only if it provably equals this
  live projection — the VIEW is the reference definition. **P-note (Info,
  deferred):** no localized concern beyond that documented trade-off.

## 5. Maintainability

- The mapper centralizes both wire shapes once (`leaderboardEntryToDto` reused by
  `seasonLeaderboardToJson`), mirroring `scoring_dto_mapper.dart` /
  `ledger_dto_mapper.dart`.
- The route is thin: method-guard → read root + principal → call use-case →
  `switch` on `Result` → `Response.json` / `errorResponse`. Identical shape to
  the scoring/ledger routes; makes no authz decision (gate is in the use-case).
- The `/seasons` subtree already carries `bearerAuth` via
  `seasons/_middleware.dart`, so there is **no local leaderboard middleware** —
  the same discipline as the other read routes.
- **M-note (Info):** the VIEW relies on the base tables' per-table self-read RLS
  rather than a `security definer` helper — matches the ledger/scoring migration
  style, keeping the attack surface minimal.

## 6. Production-readiness

- **No placeholders / TODOs / mocks** in shipped code (grep-clean across the new
  files). The in-memory `InMemoryLeaderboardRepository` and fakes live under
  `test/` only.
- **Forward-only, idempotent migration** — every statement guarded
  (`create schema if not exists` / `create or replace view` /
  `create index if not exists`); `security_invoker` applied inside a
  `do $$ … exception … null` block so a pre-PG15 server still relies on the
  base-table grants/RLS; reuses tables from 0002/0005; introduces no writable
  table/enum/trigger/points source.
- **No new external dependency** (§3 confirms: pure reuse of `postgres 3.5.12`
  read surface, `dart_frog 1.2.6`, `mocktail`, `test ^1.26.0`). Environment note
  unchanged: sandbox has no Dart toolchain — verification is by-construction +
  version-checking; "compiles & goes green" is confirmed on a Dart 3.12+ machine
  via `melos bootstrap && melos run verify`.
- **CompositionRoot** wires `getSeasonLeaderboard` in `bootstrap` (real
  `PostgresLeaderboardRepository` over the shared connection, reusing
  `competitionRepository` for the membership gate) and supplies a loud
  `_absentGetSeasonLeaderboard` stand-in backed by `_UnwiredLeaderboardRepository`
  (`seasonStandings` throws `StateError`) in `forTesting`, so a route test
  reaching an unwired slice fails loudly. Verified (lines 386, 453–456, 687–690).
- **Test coverage end-to-end:** domain (24 across two files), contracts (8),
  application (9), infrastructure hermetic (7) + DB-gated integration
  (documented scenarios), route (6, real wiring over the in-memory repos). All
  present on disk.

---

## 7. Summary of findings

| ID | Severity | Area | Status |
|---|---|---|---|
| L-1 | Low | Maintainability — dartdoc typo `SeasonLeaderboard.rankAll` (no such member) | **Fixed in-place** — comment now reads `SeasonLeaderboard.rank` |
| D-1 | Info | SSoT precision — §2/§4 said the infra hermetic test has "8 cases" | **Corrected** — it has 7 (SQL-shape+bind, bigint, empty, transient, 3 corrupt-row) |
| P-note | Info | Performance — read-time aggregation vs. materialized table | Ratified trade-off; materialize only if a future scale phase proves it hot |
| M-note | Info | Maintainability — VIEW self-read RLS style | Intentional; matches ledger/scoring migration; no change |
| S-verified | Info | Security — `security_invoker` + revoke anon + app gate primary, RLS backstop | Verified OK; no change |
| C-verified | Info | Correctness — "1224" ranks + zero row + empty board + season scoping | Verified OK by domain/application/route tests + VIEW SQL; no change |

### L-1 (Low) — dartdoc typo, fixed

`leaderboard_entry.dart` `projected()` referenced `[SeasonLeaderboard.rankAll]`
in a comment; the actual ranking entry point is `SeasonLeaderboard.rank`. This
is a comment-only inaccuracy (a dead dartdoc reference — no code path or symbol
named `rankAll` exists anywhere, verified by grep). Fixed in-place to
`[SeasonLeaderboard.rank]`. No behavioural change; Low because it could only
mislead a reader, never the compiler or a test.

### D-1 (Info) — hermetic test count precision, corrected

The delivery record in §2 and the §4 checklist described the infrastructure
hermetic test as having "8 cases". Direct count is **7** (maps-rows+binds-season,
bigint SUM/count, empty board, transient passthrough, and three corrupt-row
cases: participant-id / non-int-total / absent-joined_at). The §2/§4 text is
corrected to "7 cases" for SSoT accuracy. No coverage gap — the enumerated
branches are all exercised; only the tally was off by one.

---

## 8. Exit criterion

Leaderboards delivered end-to-end: a season member reads the ranked standings — a
read-side projection over the ratified append-only ledger — via
`GET /seasons/{id}/leaderboard` behind `bearerAuth`; totals equal the
participants' balances (Axiom 5, a single protected truth for points); ranking is
the pure domain's standard-competition "1224" rule with a deterministic total
tie-break; every enrolled participant appears (never-credited = zero row); an
empty season is a legitimate empty board; a non-member is refused
`leaderboard.not_a_participant`. Axioms 1/2/4/5/6 honoured physically (social-
first but season-scoped visibility, server-only totals, no group reference, a
projection VIEW with no second points source, `security_invoker` self-read RLS +
anon denied as the backstop). No new external dependency; `tooling/import_lint`
unchanged. Six-way review GREEN, one Low (comment) fixed in-place and one Info
(count) corrected. Ready to advance to **Groups** (next phase per Roadmap
ADR 0008).
