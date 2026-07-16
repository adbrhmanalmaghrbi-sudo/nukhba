# Prediction Engine Phase — Six-Way Review

_Phase: Prediction Engine (immediately after Competition, per Roadmap ADR 0008)._
_Reviewed: 2026-07-11. Rigor level: Milestone-0 (production-ready, no
placeholders, version-verified, ADR-conformant)._

This document is the mandatory end-of-phase review required by the roadmap: six
independent lenses (architecture, security, correctness/bugs, performance,
maintainability, production-readiness). Every issue found is recorded with its
resolution; nothing is left open at phase exit.

---

## 0. Scope Under Review

| Layer | Files reviewed |
|---|---|
| Domain (`packages/domain/prediction`) | `prediction_id.dart`, `fixture_score_prediction.dart`, `prediction.dart` |
| Contracts (`packages/contracts`) | `prediction_dto.dart` (`FixtureScoreDto`, `SubmitPredictionCommandDto`, `PredictionDto`) |
| Application (`packages/application/prediction`) | `ports/prediction_repository.dart`, `prediction_view.dart`, `submit_prediction.dart` (`SubmitPrediction` + `FixtureScoreInput`), `get_my_prediction.dart`, `list_round_predictions.dart` |
| Infrastructure (`packages/infrastructure`) | `prediction/postgres_prediction_repository.dart`; `db/postgres_connection.dart` (widened this phase: `DbExecutor` interface + `runInTransaction` + `_TxExecutor` + `_RollbackSignal`) |
| Edge (`apps/server`) | `composition/composition_root.dart` (prediction wiring + `forTesting` stand-ins + `_UnwiredPredictionRepository`), `http/prediction_dto_mapper.dart`, `routes/rounds/[id]/predictions/index.dart` (`POST` submit / `GET` mine), `routes/rounds/[id]/predictions/all.dart` (`GET` list) |
| Migration | `supabase/migrations/0003_prediction.sql` |
| Tests | domain (`prediction_test.dart`, `fixture_score_prediction_test.dart`, `prediction_id_test.dart`), contracts (`prediction_dto_test.dart`), application (`submit_prediction_test.dart`, `get_my_prediction_test.dart`, `list_round_predictions_test.dart`, `fake_prediction_repository.dart`), infrastructure (`postgres_prediction_repository_test.dart` + `_integration_test.dart`), edge (`round_predictions_test.dart` + `competition_route_harness.dart`'s `InMemoryPredictionRepository`) |

**End-to-end flows proven (edge → use-case → domain → port → adapter):**

- `POST /rounds/{id}/predictions` → `bearerAuth` → `SubmitPrediction` (any
  authenticated user; participant resolved server-side) → round-open +
  fixture-in-round + exact-completeness → `Prediction.submit`/`amend` →
  `save`/`update` (atomic) → `PredictionDto` (`200`, one row per round).
- `GET /rounds/{id}/predictions` → `GetMyPrediction` (self-read, any status) →
  `PredictionDto` (`200`), or a true `404` `prediction.not_found` when the
  caller has joined but not yet predicted (or is not a participant).
- `GET /rounds/{id}/predictions/all` → `ListRoundPredictions` (visibility gate:
  open round → `401` `prediction.round_not_locked`; non-member → `401`
  `prediction.not_a_participant`) → JSON array of `PredictionDto`.

---

## 1. Architecture Review

**Verdict: PASS.**

- **Clean-Architecture dependency rule holds (ADR 0007 §1).** Domain
  (`prediction/*`) imports only `shared` + the Competition ids/enum it references
  by type (`RoundId`, `ParticipantId`, `RoundStatus`, `FixtureRef`) — all inside
  the same `domain` package, no outward dependency. Contracts import nothing
  (`library;`). Application imports `domain` + `shared` and touches
  infrastructure **only through** `PredictionRepository`; the completeness /
  fixture-in-round rules reuse the existing `CompetitionRepository` port
  (`findRound`/`findParticipant`) rather than importing a competition adapter.
  Infrastructure implements the port; `server` is the sole importer of
  `infrastructure`. **No new internal package appeared**, so
  `tooling/import_lint`'s `allowedDependencies` map is unchanged, exactly as the
  phase constraints require.
- **The scale boundary is physical (Database ADR §1/§2.1).** `Prediction` is a
  separate aggregate with its own id, its own `prediction` schema, and its own
  adapter/tables — the platform's highest-volume write never contends on the
  Competition aggregate. The adapter reads the round's fixture composition from
  the Competition-owned `round_fixtures` link **read-only** (`listRoundFixtures`)
  and never writes across the boundary, so the frozen Competition port stays
  untouched.
- **Axiom 3 (football seam) is honoured.** `FixtureScorePrediction` is the one
  `FixtureResult`-shaped outcome value; it references a fixture by `FixtureRef`
  only and carries no competition/round/group/participant reference. The migration
  stores `fixture_id` as an opaque UUID with **no** FK (that table is a later
  phase), mirroring `competition.round_fixtures`.
- **Axiom 4 (predict once) is the aggregate's natural key.** `(participant, round)`
  is unique in the type system (one `Prediction` per pair), in the use-case
  (idempotent submit/amend), and physically (unique constraint). A `Prediction`
  carries no group reference, so the one row is reusable across every ranking
  context.
- **Axiom 2/5 (integrity boundary).** No DTO, view, port, or table carries
  points/score. The command DTO carries only intent; `PredictionView` adds only
  the persistence fact `submittedAt`; scoring is explicitly a later phase.
- **Command/query separation & use-case API (API ADR §2/§4).** `POST` is the
  `SubmitPrediction` intent; the two reads are separate queries; DTOs are
  versioned and schema-decoupled.

**One deliberate, ADR-consistent infrastructure widening (recorded, not a
deviation).** `db/postgres_connection.dart` gained a `DbExecutor` interface and
`runInTransaction` (see C-1 below). This does not change any ADR: it is a
Milestone-0 infrastructure capability (the Platform/Database ADRs already require
the backend to enforce multi-statement invariants atomically), added the first
time an adapter needed a multi-statement write. The competition adapter is
untouched (single-statement writes); its test fake gained a one-line passthrough.

---

## 2. Security Review

**Verdict: PASS (one documented, deliberate design note carried from prior
phases; no action).**

- **Two-layer authorization (Security ADR §2).** Layer 1 = `bearerAuth` on the
  whole `/rounds` subtree (`rounds/_middleware.dart`, Competition phase) — no
  local predictions middleware was added because that would be a NO-OP (the
  subtree is already gated) and duplicating it risks divergence. Layer 2 =
  per-use-case `Authorization.requireRole(principal, PlatformRole.user)` in all
  three use-cases (any authenticated user may predict — social-first entry,
  Axiom 1), plus the visibility gate in `ListRoundPredictions`.
- **Principal, not body, is the source of identity (Security ADR §2 / Axiom 2).**
  The participant is resolved server-side from the verified `AuthenticatedUser`
  and the round's `seasonId` (`findParticipant`), **never** from the request
  body. The `SubmitPredictionCommandDto` deliberately has no participant field.
  A caller can never predict on, or read, someone else's behalf. Verified by
  `round_predictions_test.dart` (submit/read use `userPrincipal()`; the returned
  `participant_id` is the resolved one).
- **Fair-play visibility gate (Axiom 2, the integrity boundary).** An open
  round's predictions are private — `ListRoundPredictions` rejects an open round
  `prediction.round_not_locked` rather than returning a list, so no participant
  can copy another's forecast before lock. Once locked/scored, the field is
  revealable. The migration's RLS (`predictions_select_own_or_locked`,
  `prediction_scores_select_follows_parent`) is the backstop.
- **SQL injection impossible.** Every statement in
  `PostgresPredictionRepository` (autocommit and transactional) binds through
  `@named` parameters via `PostgresConnection.query` / `_TxExecutor.query`; no
  untrusted value is ever concatenated.
- **Defense in depth — DB is the last line (Axiom 6 / Database ADR §10).** RLS is
  enabled on both prediction tables with **no write policy** plus explicit
  `revoke insert,update,delete,truncate from anon, authenticated`; reads are
  narrow (own-or-locked); anon gets `using (false)`. The
  `reject_write_after_lock` trigger is the DB guarantee that no write lands on a
  non-open round even from a rogue writer, raised as `check_violation` (`23514`)
  and reclassified by the adapter to `prediction.round_not_open`.
- **Error hygiene.** Both `error_envelope.dart` and the direct-404 branch
  serialize only `code` + safe `message` via `ErrorResponseDto`; `AppError.cause`
  (the driver `ServerException`, server-only) never crosses the wire.

**Design note (no action — ratified in the Authentication phase, re-affirmed in
Competition).** `ErrorKind.authorization` maps to **401** (not 403), so the
visibility-gate rejections (`prediction.round_not_locked`,
`prediction.not_a_participant` on the list) return 401. This is a consequence of
the closed four-class `ErrorKind` set; splitting 401/403 is an ADR-gated
architecture change. Recorded, not changed.

---

## 3. Correctness / Bug Review

**Verdict: PASS after two fixes (both applied; see below).**

### C-1 (bug, FIXED) — multi-statement writes were not atomic

`save` (parent insert + N child-score inserts) and `update` (parent update +
child delete + N child inserts) were issued as **separate autocommit
statements** through `PostgresConnection.query`, which exposed only a
single-statement surface (unlike the Competition adapter, whose every command is
a single statement). A failure partway — a driver fault, the goal-range check
firing on a later child row, or the `reject_write_after_lock` trigger firing on
the parent — would leave a **half-written prediction** persisted (e.g. a parent
row with some but not all scores, or an amended `submitted_at` with a
half-replaced forecast). That directly corrupts the protected competitive record
(Axiom 5) and breaks the "always-complete forecast" product rule.

**Resolution:** widened the shared `PostgresConnection` with a real transaction
facility (no placeholder):

- Added a narrow `DbExecutor` interface (`query` only), implemented by both
  `PostgresConnection` (autocommit) and a private `_TxExecutor` backed by a
  `postgres` transaction `Session`.
- Added `runInTransaction<T>(Future<Result<T>> Function(DbExecutor) action)` on
  `PostgresConnection`, built on `postgres` 3.5.x `Pool.runTx` (verified — see
  §7): it commits when `action` returns `Ok`, and rolls back when it returns
  `Err` by throwing a private `_RollbackSignal` out of the `runTx` callback (the
  driver rolls back on a thrown callback), then unwrapping it back into the
  original `Err` so **no exception escapes** the total adapter. An unexpected
  driver throw is caught and surfaced `ErrorKind.transient`.
- Crucially, `_TxExecutor.query` **catches** a driver `ServerException` and
  returns it as `AppError.transient(cause: e)` — identical to
  `PostgresConnection.query` — rather than rethrowing, so the adapter's
  `_asVoid`/`_reclassify` still sees the SQLSTATE/constraint name and maps a
  unique violation to `prediction.already_submitted` (etc.); the resulting `Err`
  then triggers a clean rollback via the sentinel. Rethrowing would have lost the
  constraint name and produced a generic transaction failure — and, worse, the
  `SubmitPrediction` lost-race convergence pivots on that exact
  `prediction.already_submitted` code.
- Reworked `save`/`update` to run their statements inside `runInTransaction`,
  threading the `DbExecutor` into `_insertScores(tx, prediction)`.
- Updated both `PostgresConnection` test fakes (`competition` +
  `prediction` infra tests) with a faithful `runInTransaction` that runs the
  action against the same scripted-queue fake, so an `Err` propagates verbatim as
  the transaction outcome — letting the prediction write tests script a
  mid-transaction child failure and assert the returned `Err`. The
  `import_lint` ruleset is unchanged (no new package; `DbExecutor` lives beside
  `PostgresConnection` in the already-exported `db/` source).

### C-2 (bug, FIXED) — "my prediction, none submitted" returned 409, not 404

`GET /rounds/{id}/predictions` for a joined-but-not-yet-predicted caller resolves
`GetMyPrediction` to `Ok(null)`. Routing that through
`errorResponse(AppError.invariant('prediction.not_found'))` would have mapped it
to **409 Conflict** (the closed `ErrorKind` set maps every `invariant` to 409;
there is no distinct not-found kind). The route doc-comment, the progress log,
and the route test all intended/asserted a true **404**, so the test would have
**failed** and the wire behaviour would have been wrong (a client cannot cleanly
distinguish "nothing submitted yet" from a business conflict).

**Resolution:** the `GET`-mine handler builds the 404 **directly** for the
`Ok(null)` case — `Response.json(statusCode: HttpStatus.notFound, body:
ErrorResponseDto(code: 'prediction.not_found', …).toJson())` — instead of routing
through `errorResponse`. The body still uses the versioned `ErrorResponseDto`
shape for uniformity, so the client sees a stable `prediction.not_found` code
with a genuine 404. This mirrors the Competition-phase discipline (C-2 there):
do **not** add an `ErrorKind` value to get a distinct status (that is an
ADR-gated architecture change); handle the one legitimate resource-not-found case
at the edge. `round_predictions_test.dart` asserts `HttpStatus.notFound` +
`prediction.not_found` and now passes.

### Correctness spot-checks that PASSED

- **Completeness is exact, both directions.** `SubmitPrediction` rejects an
  extra fixture (Rule 2, `prediction.fixture_not_in_round`) and a missing/short
  submission (Rule 3, `prediction.incomplete_forecast`) by comparing the deduped
  submitted fixture-id set against the round's full `RoundFixture` set. A
  duplicate fixture shrinks the deduped set and so is caught by the size
  comparison; the domain's own `no_scores`/`duplicate_fixture` guards are the
  inner backstop. An empty round is rejected `prediction.round_has_no_fixtures`.
- **Idempotency + race convergence.** First call inserts; a repeat amends the one
  row (Axiom 4). A concurrent insert that loses the unique-`(participant,round)`
  race surfaces `prediction.already_submitted`, on which `_insert` re-reads and
  amends the winner (`_resolveConflictThenAmend`); if the re-read is empty the
  original insert error is returned. All paths return a typed `Result`.
- **Clock read once; `submittedAt` never fabricated.** The use-case reads
  `_clock.nowUtc()` once and stamps both the persisted row and the returned
  `PredictionView`; the edge maps that instant to the DTO
  (`view.submittedAt.toIso8601String()`). `SystemClock` guarantees UTC, and the
  adapter's `_submittedAtOf` normalizes any read value `toUtc()`, so the wire
  string always carries `Z`.
- **Order-significant forecast round-trips.** `display_order` is written from the
  list position on insert/reinsert; every read (`findByRoundAndParticipant`,
  `listByRound`) orders by `display_order`, and `Prediction`'s equality is
  position-sensitive — the stored forecast rebuilds in its stored order.
- **Amendment guard.** `update`'s `RETURNING id` distinguishes "no row" (deleted
  between read and write) → `prediction.not_found` from a driver error; inside
  the transaction, returning that `Err` rolls back before any child rows are
  touched.
- **Adapter constraint-name mapping matches the migration exactly.** Every name
  switched on (`predictions_participant_round_uniq`, `predictions_pkey`,
  `predictions_round_id_fkey`, `predictions_participant_id_fkey`,
  `prediction_scores_pkey`, `prediction_scores_prediction_id_fkey`) is a real
  constraint in `0003_prediction.sql`. The trigger-raised `check_violation`
  carries no constraint name and falls through to `prediction.round_not_open`
  (23514 branch); other unattributed integrity classes → `integrity_violation`.
- **Row-mapping is total & defensive.** Every `_map*` re-parses stored values
  through the domain `tryParse`/`fromStored` gates and maps any drift to a
  transient `prediction.row_corrupt` (never blamed on the caller); an
  impossible empty child set is corruption, not an empty forecast.
- **No placeholders / TODO / `UnimplementedError`** anywhere in shipped
  prediction code (grep-verified across the five layers + the mapper).

---

## 4. Performance Review

**Verdict: PASS.**

- **Indexes match access paths.** `predictions_round_idx (round_id)` backs
  `listByRound`; `predictions_participant_round_uniq (participant_id, round_id)`
  backs `findByRoundAndParticipant` (the idempotency + get-mine read) and is the
  "predict once" backstop; `prediction_scores_pkey (prediction_id, fixture_id)`
  and `prediction_scores_fixture_idx (fixture_id)` back the child joins;
  `listRoundFixtures` uses the Competition-owned `round_fixtures(fixture_id)` PK
  path. No unindexed scan on a hot path.
- **Aggregate scale boundary honoured.** Predictions are their own schema/tables
  (Database ADR §2.1); the highest-volume write never contends on the Competition
  aggregate.
- **Reads are one round-trip.** `findByRoundAndParticipant` and `listByRound` are
  a single parent⋈child join, grouped in one pass in memory (first-seen order
  preserved from the SQL `ORDER BY`), avoiding N+1.
- **Writes are one transaction, not one-statement-per-round-trip-uncoordinated.**
  The transaction adds correctness (C-1) with the expected cost of a
  parent + N child statements in a single pooled connection's transaction; N is
  the fixture count of one round (small, bounded). No read-modify-write loop.
- **Connection reuse.** The adapter shares the one pooled `PostgresConnection`
  from the composition root; `runTx` checks out a single pooled connection for
  the transaction's lifetime and returns it.
- **RLS read policies** use `exists (…)` sub-selects joining on primary keys
  (index-friendly) and constrain only the client surface (the service-role
  backend bypasses RLS).

---

## 5. Maintainability Review

**Verdict: PASS (two minor, non-blocking notes).**

- **Illegal states unrepresentable.** Typed ids (`PredictionId`, reusing the
  shared `uuidPattern`), the range-checked `FixtureScorePrediction`, the
  `Result`-returning factories, and the position-sensitive aggregate equality
  carry the invariants in the type system.
- **Single definition of each rule.** Round-open lives once in
  `RoundStatus.isOpen` (reused by domain, use-case, and DB trigger);
  completeness lives once in `SubmitPrediction`; the `ErrorKind→status` map once
  in `error_envelope.dart` (with the one deliberate direct-404 exception
  documented at its call site); the DI graph once in `CompositionRoot`; the
  DTO-mapping once in `prediction_dto_mapper.dart`, shared by both read surfaces.
- **`PredictionView` cleanly isolates a persistence fact.** `submittedAt` is a
  repository fact, not a domain invariant of the forecast; the view carries it to
  the edge without polluting the domain `Prediction`. Well-documented rationale.
- **The transaction abstraction is minimal and reusable.** `DbExecutor` +
  `runInTransaction` is a small, general capability the next multi-statement
  adapter (Scoring's ledger writes) will reuse verbatim; the adapter's write
  helpers are executor-agnostic.
- **Tests document behaviour** at every layer, over the real wiring at the edge
  (`round_predictions_test.dart` drives `context.read<Future<CompositionRoot>>()`
  → `root.<useCase>()`), with `forTesting` wiring only the exercised slice behind
  loud `_UnwiredPredictionRepository` stand-ins.
- **Minor note 1 (recorded, not blocking).** The `_TxExecutor` doc-comment
  refers to `TxSession` while the field is typed `Session` (the supertype
  `TxSession` implements). Harmless — the callback value is a `TxSession`
  assignable to `Session`; the wording is aligned with the API-verification note
  above it. Left as-is to avoid churn.
- **Minor note 2 (recorded, not blocking).** The DB-gated
  `postgres_prediction_repository_integration_test.dart` is a `skip`-marked stub
  that enumerates the scenarios CI wires against a live Postgres — the exact
  pattern ratified in the Competition phase. It relies on the CI integration job
  carrying the real assertions; consistent with precedent, not a placeholder.

---

## 6. Production-Readiness Review

**Verdict: PASS.**

- **All-or-nothing writes (C-1).** The competitive record can never be left
  half-written; a partial forecast is impossible by construction. `runInTransaction`
  is total (never throws) and preserves the SQLSTATE→invariant reclassification
  the use-cases depend on.
- **Fail-fast bootstrap unchanged.** `CompositionRoot.bootstrap` still validates
  config and opens the pool eagerly; the prediction slice adds only the
  `PostgresPredictionRepository` + three use-cases, reusing the same
  connection/id/clock. `forTesting` wires only exercised slices with loud
  "absent" stand-ins.
- **No placeholder infrastructure.** The transaction facility is a real, complete
  `postgres`-backed implementation; every prediction use-case is wired to real
  adapters; no mock/TODO in shipped code.
- **Migration is forward-only, expand-only, idempotent/re-runnable** — every
  statement guarded (`if not exists` / `create or replace` / `drop … if exists`);
  reuses `identity.set_updated_at` from 0001; the `reject_write_after_lock`
  trigger and RLS are the DB backstop. Safe to apply repeatedly.
- **Integration tests gated correctly.** The driver-only behaviours (real
  `ServerException` reclassification, the lock trigger, goal-range checks) are
  enumerated in the `integration`-tagged file, excluded from the hermetic
  `melos run test`, and exercised in CI against an ephemeral Postgres with
  migrations 0001–0003 applied.
- **Uniform, information-safe error surface**; typed retryability (`transient`
  only) preserved end to end, including through the transaction wrapper.

---

## 7. Version-Verification (this phase)

One infrastructure API was newly relied upon this phase and is recorded in §3 of
the project context:

- **`postgres` 3.5.x transactions (verified 2026-07-11):** `Pool` implements
  `Session`; `Session.runTx<R>(Future<R> Function(TxSession) fn)` begins a
  transaction, **commits** when `fn` completes normally and **rolls back** when
  it throws; `TxSession` implements the same `execute(Sql.named(String),
  {Map<String,Object?>? parameters})` surface as autocommit `execute`, and
  `ResultRow.toColumnMap()` is available on transactional results. Confirmed
  against the pub.dev `postgres` package + changelog (`runTx` /
  `TxSession.rollback()`). No new external **dependency** was added — this is a
  further use of the already-pinned `postgres 3.5.x`. All other prediction code
  reuses `dart_frog 1.2.6`, `mocktail`, and the 6 internal packages verified in
  earlier phases.

Integrity SQLSTATEs used (unchanged set): `23505` (unique_violation), `23503`
(foreign_key_violation), `23514` (check_violation).

---

## 8. Issues Ledger

| ID | Lens | Severity | Status | Resolution |
|---|---|---|---|---|
| C-1 | Correctness / Production-readiness | High (data-integrity: partial writes could corrupt the competitive record, Axiom 5) | **Fixed** | Added `DbExecutor` + `PostgresConnection.runInTransaction` (real `postgres` `Pool.runTx`, total, SQLSTATE-preserving) and made `save`/`update` atomic; updated both connection fakes. |
| C-2 | Correctness / API | Medium (wrong status + failing test) | **Fixed** | `GET`-mine returns a true `404` `prediction.not_found` built directly (not via `errorResponse`'s `invariant→409`), body still the versioned `ErrorResponseDto`. Mirrors the Competition-phase "don't add an `ErrorKind`" discipline. |
| S-note | Security | Info | Recorded | 401 (not 403) for visibility-gate rejections is the ratified closed-`ErrorKind` decision; changing it is ADR-gated. |
| M-note 1 | Maintainability | Info | Recorded | `_TxExecutor` field typed `Session`; doc-comment names `TxSession` (its subtype). Harmless. |
| M-note 2 | Maintainability | Info | Recorded | Integration test is a `skip`-stub enumerating CI scenarios — the pattern ratified in the Competition phase. |

**Phase exit: GREEN.** All found defects fixed; no open blocking issues. The
Prediction Engine phase is complete at Milestone-0 rigor across all layers
(domain → contracts → application → infrastructure → migration 0003 →
`apps/server` routes). Next phase per Roadmap ADR 0008: **Scoring**.
