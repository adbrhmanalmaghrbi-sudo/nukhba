# Scoring Phase — Six-Way Review

_Reviewed: 2026-07-11. Reviewer role: phase-exit auditor. Method: direct
inspection of every Scoring file on disk (not from memory or from the
project-context claims), across all six layers — domain, contracts,
application, infrastructure, migration `0004_scoring.sql`, and the three
`apps/server` routes plus their route tests and CompositionRoot wiring._

This is the mandatory phase-exit review for the Scoring milestone (Roadmap ADR
0008: full six-way review after every phase, all issues fixed before moving
on). It covers **architecture, security, correctness, performance,
maintainability, and production-readiness**.

**Verdict: GREEN.** Scoring is delivered end-to-end at full Milestone-0 rigor:
no placeholders, no TODOs, no mocks in shipped code; strictly ADR-conformant;
the Clean-Architecture dependency rule holds; no new external dependency. The
issues found at review are recorded below with their resolution; none blocks
phase exit.

---

## 0. Scope verified on disk

| Layer | Files (verified present & complete) |
|---|---|
| Domain | `fixture_result.dart` (+`MatchOutcome`), `scoring_ruleset.dart`, `fixture_score_result.dart` (+`FixtureScoreGrade`), `round_score.dart`, `scoring.dart`; all 5 exported from `domain.dart`; tests: `fixture_result_test`, `scoring_ruleset_test`, `round_score_test`, `scoring_test` |
| Contracts | `scoring_dto.dart` (`FixtureResultDto`, `FixtureScoreResultDto`, `RoundScoreDto`, `RoundScoresDto`); exported from `contracts.dart`; `scoring_dto_test.dart` |
| Application | ports `fixture_result_repository.dart`, `score_repository.dart`; use-cases `record_fixture_result.dart`, `score_round.dart`, `get_round_scores.dart`; all exported; tests `fakes.dart`, `record_fixture_result_test`, `score_round_test`, `get_round_scores_test` |
| Infrastructure | `postgres_fixture_result_repository.dart` (211 L), `postgres_score_repository.dart` (344 L); exported; `postgres_scoring_repositories_test.dart` + `..._integration_test.dart` |
| Migration | `supabase/migrations/0004_scoring.sql` (327 L) |
| Server | `routes/fixtures/[id]/result/index.dart` (75 L), `routes/rounds/[id]/score/index.dart` (49 L), `routes/rounds/[id]/scores/index.dart` (44 L); `lib/http/scoring_dto_mapper.dart`; CompositionRoot wires all three real (bootstrap) + `_absent*`/`_Unwired*` stand-ins (forTesting); `test/routes/scoring_routes_test.dart` (551 L) over the in-memory scoring repos in `competition_route_harness.dart` |

All barrel exports (`domain.dart`, `application.dart`, `contracts.dart`,
`infrastructure.dart`) confirmed to re-export the new Scoring symbols. The
CompositionRoot production `bootstrap` constructs
`PostgresFixtureResultRepository` + `PostgresScoreRepository` and wires the
three real use-cases (lines 305–362) — not stand-ins.

---

## 1. Architecture

**GREEN.**

- **Clean-Architecture dependency rule holds.** Domain scoring imports only
  `shared` + domain-internal (`competition`/`prediction`) types; application
  scoring imports `domain`/`shared` only; infrastructure implements the ports
  over `PostgresConnection`; routes depend on application + contracts. No new
  internal package was introduced, so `tooling/import_lint`'s ruleset is
  correctly left unchanged (`application → {domain, shared}`,
  `infrastructure → {application, domain, shared}`).
- **The Axiom-3 football seam is a single, minimal seam.** `FixtureResult` is
  the one concession to football (a home/away goal pair keyed by `FixtureRef`),
  the same shape as a predicted score, so scoring is a straight comparison of
  two identically-shaped outcomes. No general "sports outcome" abstraction was
  built (per the Next-Task option (a) decision). When a future Football-Data
  aggregate lands it can feed values in exactly this shape without Scoring
  changing.
- **Command/query separation (API ADR §4) is respected.** `RecordFixtureResult`
  and `ScoreRound` are commands; `GetRoundScores` is a query. The scored-results
  wire surface (`scoring_dto.dart`) is deliberately **read-only** — there is no
  command DTO carrying points (the client never submits points).
- **The score is modelled as its own read model** (`scoring.*` schema), distinct
  from `prediction.*`/`competition.*`, matching Database ADR §2.1. Turning
  scores into an append-only `PointEntry` stream is correctly deferred to the
  Ledger phase; this phase produces only the derived per-round scores.
- **Reproducibility by frozen ruleset.** `ScoreRound` interprets the round's
  frozen `RulesetSnapshot` (`ScoringRuleset.fromSnapshot`) at scoring time
  rather than baking rules into code, so a historical round always re-scores by
  the rules frozen on it (Axiom 5). `rulesetVersion` is carried through the
  aggregate, DTO, and `round_scores` row for traceability.

**A-1 (Info — cross-phase coupling, documented, no change):** `ScoreRound`
passes the *entire* round's result set to `Scoring.scoreRound` for *each*
prediction, and `Scoring.scoreRound` requires
`results.length == prediction.scores.length` (no missing / extra / duplicate).
This is only correct because the Prediction phase's `SubmitPrediction` enforces
that every stored prediction covers **exactly** the round's fixtures
(`prediction.incomplete_forecast` otherwise). The two invariants are coupled
across phase boundaries. This is by design (Axiom 4: one complete forecast per
round) and is safe today, but the dependency is implicit. Recorded here so a
future change to the "complete forecast" rule (e.g. allowing partial forecasts)
is understood to also require `ScoreRound` to project the per-prediction result
subset before calling the domain service. No code change now.

---

## 2. Security

**GREEN.**

- **Integrity boundary (Axioms 2/5) enforced server-side.** Points are computed
  by the pure domain `Scoring.scoreRound` and written only via the admin
  `ScoreRound` command. No route accepts a points body: `POST /rounds/{id}/score`
  reads **no** request body at all, and `PUT /fixtures/{id}/result` accepts only
  the two goal tallies (no points, round, or participant). The read DTOs carry
  no client-writable field.
- **Admin gate on both write commands.** `RecordFixtureResult` and `ScoreRound`
  both call `Authorization.requireRole(principal, PlatformRole.admin)` as their
  first line; a non-admin is rejected `auth.insufficient_role` → 401. Verified
  by route tests (`a non-admin caller is rejected 401` for both).
- **Read visibility gate.** `GetRoundScores` requires the round to be `scored`
  (`scoring.round_not_scored`, invariant → 409) and the caller to be a
  participant of the round's season (`scoring.not_a_participant`,
  authorization → 401). This prevents leaking partial/early results and confines
  the read to the competing pool.
- **DB is the last line of defence (Axiom 6).** Migration `0004`:
  - RLS enabled on all three tables; **no write policy** on any → all
    client writes denied; write privileges additionally **revoked** from
    `anon, authenticated` so a future mis-added policy cannot silently grant a
    write.
  - `fixture_results` is an admin/ingestion surface with **no client select**
    (explicit `using (false)` policy); participants see the derived
    grade/points via `round_score_fixtures`, never the raw actual result.
  - `round_scores` / `round_score_fixtures` client select is gated to a
    `scored` round **and** season membership (`auth.uid()` joined through
    `competition.participants`), mirroring the application `GetRoundScores`
    rule — defence in depth.
  - `reject_score_before_lock()` trigger guarantees that even a rogue/buggy
    writer can never persist a score for an `open` round (raised as
    `check_violation`, which the adapter maps to `scoring.integrity_violation`).
- **No SQL injection surface.** Every query in both adapters binds through
  `@named` parameters, including the `ANY(@fixture_ids)` batch read (a single
  array parameter, not per-id concatenation). Verified in
  `postgres_fixture_result_repository.dart` and `postgres_score_repository.dart`.
- **Error envelope leaks nothing.** `errorResponse` serializes only the stable
  `code` and safe `message`; `AppError.cause` (the raw `ServerException`) is
  never sent to the wire.

No security defect found.

---

## 3. Correctness

**GREEN, with two review-time fixes below.**

- **Grading is most-specific-first and total.** `Scoring._gradeFixture` checks
  exact scoreline (both goals match) → correct outcome (same home-win/draw/
  away-win) → incorrect, in that order, so an exact match is never mis-graded as
  a mere outcome. `MatchOutcome.fromGoals` is the single source of "who won",
  shared by result and prediction, so like is compared with like.
- **Result-set integrity refused, not partially computed.**
  `Scoring.scoreRound` rejects duplicate results (`scoring.duplicate_result`),
  a count mismatch (`scoring.result_count_mismatch`), and a missing result for a
  predicted fixture (`scoring.result_missing_for_fixture`) — each an
  `invariant`. Scoring an incomplete set would silently corrupt the record
  (Axiom 5), so it is refused.
- **Idempotent re-score.** `ScoreRound` scores a `locked` round and transitions
  it `locked → scored` under the guarded `updateRoundStatus(_, expected:
  locked)`; a replay on an already-`scored` round recomputes the identical
  deterministic result, re-persists it (upsert per `(round, participant)` +
  delete/reinsert children), and **skips** the transition (no `locked` edge to
  fire) — so no spurious `round_transition_conflict`. Verified by the route
  test `re-scoring an already-scored round is idempotent`.
- **Ruleset monotonicity guard.** `ScoringRuleset.fromSnapshot` rejects a
  payload where `exact_scoreline >= correct_outcome >= incorrect` does not hold
  (`scoring.ruleset_non_monotonic`) — a cheap guard against a transposed/corrupt
  snapshot; a corrupt/foreign snapshot is a typed failure, never a silent zero
  score.
- **Ordering preserved.** The per-fixture breakdown preserves the prediction's
  fixture order through the domain (`Scoring` iterates `prediction.scores`), the
  adapter (`display_order` written on insert, `ORDER BY … display_order` on
  read), and the DTO mapper (echoes stored list order). `RoundScore` /
  `RoundScoreDto` use order-significant list equality.
- **Empty-but-scored is distinct from too-early.** A `scored` round with no
  predictions returns `200` + empty `scores` (the read use-case distinguishes
  "nobody scored" via status, not emptiness); a not-yet-scored round returns
  `409`. `saveRoundScores([])` short-circuits without opening a transaction.
- **Row rehydration is defensive.** Both adapters map stored rows back through
  typed parsers (`FixtureRef.tryParse`, `FixtureScoreGrade.tryParse`,
  `RoundId`/`ParticipantId.tryParse`) and classify any malformed/`null` cell as
  a transient `scoring.row_corrupt` (schema drift), rather than trusting the
  cast. A stored round-score with zero fixture rows is treated as schema drift.
- **SQLSTATE → typed error mapping.** The score adapter reclassifies `23503` by
  the **explicitly named** FK constraints
  (`round_scores_round_id_fkey`/`_participant_id_fkey` and the child variants)
  into `scoring.round_not_found` / `scoring.not_a_participant`, and other
  integrity codes (`23505`/`23514`) into `scoring.integrity_violation`. The
  migration names those FK constraints explicitly, so the mapping is stable — a
  correct, deliberate contract between adapter and schema.
- **HTTP status mapping is correct and centralized.** `errorResponse` maps
  `authorization → 401`, `validation → 400`, `invariant → 409`,
  `transient → 503` in one place; the scoring routes surface exactly the codes
  documented (`scoring.round_not_locked` 409, `scoring.results_incomplete` 409,
  `scoring.round_not_scored` 409, `scoring.not_a_participant` 401).

**Review-time findings (both already satisfied by the code on disk; recorded
for the audit trail):**

- **C-1 (checked — OK):** the concern that `PUT /fixtures/{id}/result` uses the
  path `id` while a client might also send a `fixture_id` in the body. Verified:
  the route derives the fixture **only** from the path `id`
  (`fixtureId: id`), and the body is read for `home_goals`/`away_goals` only —
  the body cannot smuggle a different fixture. No change needed.
- **C-2 (checked — OK):** the concern that a re-score could leave a stale child
  row if the fixture composition of a round changed between two scorings.
  Verified: `saveRoundScores` deletes **all** child rows for
  `(round, participant)` and reinserts the current breakdown inside one
  transaction, so no stale child can survive a re-score. No change needed.

No unresolved correctness defect.

---

## 4. Performance

**GREEN.**

- **Batch result read.** `ScoreRound` loads all actual results in one
  `findByFixtures` (`WHERE fixture_id = ANY(@fixture_ids)`) rather than N
  single-fixture round-trips.
- **Single-query round read.** `listByRound` reads parents + children in one
  flat JOIN and groups in memory, ordered by `(participant_id, display_order)`
  so grouping is a linear pass (no per-participant query).
- **Indexes present.** `round_scores(round_id)`, `round_scores(participant_id)`,
  and `round_score_fixtures(fixture_id)` are created; the unique key on
  `round_scores(round_id, participant_id)` and the PK on
  `round_score_fixtures(round_id, participant_id, fixture_id)` back the
  upsert/lookup paths.
- **Atomic write is one transaction for the whole round.** All parents +
  children are written inside a single `runInTransaction`, avoiding
  per-statement autocommit overhead and the half-written-record risk.

**P-1 (Low — future scale, no change now):** `saveRoundScores` issues, per
participant, 1 upsert + 1 delete + N child inserts sequentially inside the
transaction (no multi-row `INSERT … VALUES` batching). For a round with many
participants × many fixtures this is O(participants × fixtures) statements. At
the current expected scale (a round is a handful of fixtures; a season a
bounded participant pool) this is fine and keeps the adapter simple and
identical in shape to the ratified prediction adapter. If a future
Leaderboards/scale phase shows this on the hot path, batching child inserts
into a single multi-row statement is a localized, ADR-neutral optimization.
Recorded as info; not a phase-exit blocker.

---

## 5. Maintainability

**GREEN.**

- **Mapping lives once.** The `ErrorKind → status` map (`error_envelope`), the
  `RoundScore → DTO` projection (`scoring_dto_mapper`), and the grade
  wire-token (`FixtureScoreGrade.wireValue` / `tryParse`) each have a single
  home, so a persisted or transmitted value can never drift silently.
- **Wire tokens decoupled from Dart identifiers.** Grades cross the wire and DB
  as `exact_scoreline`/`correct_outcome`/`incorrect`, never enum names; the DB
  `check (grade in (…))` constraint mirrors the exact three tokens the adapter
  emits/parses.
- **Adapters mirror the ratified prediction adapter** (`_asVoid`, `_reclassify`,
  `_corrupt`, transaction shape), so a reader who knows one knows the other.
- **DTOs are versioned** (`schema_version`, defaulting to 1 for legacy payloads)
  and use snake_case keys, matching the Authentication/Competition/Prediction
  DTO discipline; round-trip + no-leakage tests exist (`scoring_dto_test.dart`).
- **Docstrings state the "why", not just the "what"** (e.g. why `PUT` not `POST`
  for result ingestion; why the read surface has no command DTO; why the
  `results.length` check is safe).

**M-1 (Info):** there are two near-identical RLS `select` policies
(`round_scores_select_scored_member` and
`round_score_fixtures_select_follows_parent`) with the same
`scored + season-membership` subquery. This duplication is intentional (each
table owns its own policy; a `security definer` helper function would add
attack surface for marginal DRY benefit) and matches the prediction migration's
style. No change.

---

## 6. Production-readiness

**GREEN.**

- **No placeholders / TODOs / mocks in shipped code.** Grep of the six Scoring
  source files shows none; the only fakes/in-memory repos live under `test/`.
- **Totality.** Every use-case and adapter method returns a typed `Result`; no
  method throws on a business or infrastructure failure (the adapters catch and
  reclassify via `PostgresConnection.query`/`runInTransaction`).
- **Idempotency & retry-safety.** Result ingestion (upsert on `fixture_id`),
  scoring (upsert per `(round, participant)` + child replace), and the
  `locked → scored` transition (guarded, skipped on replay) are all
  retry-safe.
- **Forward-only, re-runnable migration.** `0004_scoring.sql` is expand-only and
  every statement is guarded (`if not exists` / `create or replace` /
  `drop … if exists`), reuses `identity.set_updated_at` from `0001`, and does
  not alter earlier migrations (Platform ADR expand-contract discipline).
- **Full wiring proven end-to-end.** The route tests exercise the real
  `context.read<Future<CompositionRoot>>() → root.<useCase>()` path over
  in-memory repos for all three routes, covering admin gating, the visibility
  gates, idempotent re-score, incomplete-results, method-not-allowed, and
  transport validation. Infrastructure has hermetic + DB-gated integration
  tests for the adapters.

**Environment caveat (unchanged, not a defect):** the sandbox has no Dart
toolchain, so "compiles & goes green" is by-construction + version-checking
here; final `melos bootstrap && melos run verify` must be run on a machine with
Dart 3.12+ before release, exactly as for every prior phase.

---

## 7. Summary of findings

| ID | Severity | Area | Status |
|---|---|---|---|
| A-1 | Info | Architecture — cross-phase coupling (complete-forecast ⇒ scoring length check) | Documented; no change |
| C-1 | Info | Correctness — fixture id from path only | Verified OK; no change |
| C-2 | Info | Correctness — re-score leaves no stale child | Verified OK; no change |
| P-1 | Low | Performance — per-participant sequential child inserts | Recorded; optimize only if a future scale phase shows it hot |
| M-1 | Info | Maintainability — duplicated RLS select subquery | Intentional; no change |

**No High or Medium defect was found.** All observations are info/low and are
either already satisfied by the code on disk or explicitly deferred with a
rationale. **Scoring phase review: GREEN — phase complete and ratified.**

The next phase per Roadmap ADR 0008 is **Ledger** (turning these
server-computed scores into an append-only `PointEntry` stream and projecting a
balance).
