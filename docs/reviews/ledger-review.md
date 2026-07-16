# Ledger Phase — Six-Way Review

_Reviewer role: auditor, by direct on-disk inspection of every Ledger file
across all layers (2026-07-11). Phase-exit gate. The four lower layers
(domain / contracts / application / infrastructure) were delivered in prior
sessions and are unchanged this session; this review verifies them together
with the elements delivered **this** session — the migration
`0005_ledger.sql`, the `apps/server` routes + mapper + CompositionRoot wiring,
and the route tests — and confirms the phase is complete end-to-end._

Result: **GREEN.** No High or Medium defect. Findings are info/low and are
either verified already-satisfied by the code on disk or documented with
rationale; one (L-1) is a deliberate, documented refinement of the ratified
dedupe key that strictly preserves the ratified idempotency guarantee.

---

## 0. Scope verified on disk

| Layer | Files (verified present & complete) |
|---|---|
| Domain | `entry_kind.dart` (71 L, `EntryKind` closed set + `wireValue`/`requiresNonNegativeAmount`/`isDedupedPerRound`/`tryParse`), `point_entry_id.dart` (38 L), `point_entry.dart` (170 L, append-only value, no mutation API), `ledger_balance.dart` (84 L, pure projection); all exported from `domain.dart`; tests `point_entry_test.dart`, `ledger_balance_test.dart` |
| Contracts | `ledger_dto.dart` (322 L: `PointEntryDto`, `BalanceDto`, `ParticipantEntriesDto`, `PostRoundToLedgerResponseDto`); exported from `contracts.dart`; `ledger_dto_test.dart` |
| Application | ports `ledger_repository.dart` (55 L), `participant_reader.dart` (31 L); use-cases `post_round_to_ledger.dart` (142 L), `read_participant_ledger.dart` (108 L); all exported; tests `fakes.dart`, `post_round_to_ledger_test.dart`, `read_participant_ledger_test.dart` |
| Infrastructure | `postgres_ledger_repository.dart` (315 L), `postgres_participant_reader.dart` (112 L); exported; `postgres_ledger_repositories_test.dart` + `..._integration_test.dart` |
| Migration | `supabase/migrations/0005_ledger.sql` (**this session**) |
| Server | `routes/rounds/[id]/ledger/index.dart`, `routes/participants/_middleware.dart`, `routes/participants/[id]/balance/index.dart`, `routes/participants/[id]/entries/index.dart`; `lib/http/ledger_dto_mapper.dart`; CompositionRoot wires both use-cases real (bootstrap) + `_absent*`/`_Unwired*` stand-ins (forTesting); `test/routes/ledger_routes_test.dart` over the in-memory `InMemoryLedgerRepository` + `InMemoryParticipantReader` added to `competition_route_harness.dart` (**this session**) |

---

## 1. Architecture

- **Score → Ledger seam is a separate explicit command, not an event** — as
  ratified in §2 before any code. `PostRoundToLedger` reads the already-persisted
  scored round (`CompetitionRepository.findRound` gated on `RoundStatus.scored`
  + `ScoreRepository.listByRound`) and appends; it does **not** touch Scoring's
  public surface. `ScoreRound` is byte-for-byte unchanged (verified: no diff to
  any scoring file this session). The command is the synchronous, in-process
  edge of the event-driven boundary (ADR 0002); a future outbox can call the
  identical use-case. **No new architectural element** beyond a use-case +
  adapter + routes — no ADR change.
- **Clean-Architecture dependency rule** — the two new server routes and the
  mapper import `application` / `domain` / `contracts` / `shared` only;
  `CompositionRoot` remains the sole component importing `infrastructure`. **No
  new internal package** appeared (the `ParticipantReader` port lives inside the
  existing `application` package), so `tooling/import_lint` ruleset is unchanged
  — verified: no edit to `tooling/import_lint`.
- **Reference by id, no group reference (Axiom 4)** — `point_entries` names
  participant + round by id, carries no group column; the DTOs carry no group
  field; the balance/entries surface is keyed by participant id only. Verified in
  the migration and the mapper.

## 2. Security

- **Integrity boundary (Axiom 2) — server writes only.** `POST
  /rounds/{id}/ledger` reads **no request body**; the amounts are copied
  server-side from the frozen `RoundScore.totalPoints`. The admin gate lives in
  the use-case (`Authorization.requireRole(admin)`); the route makes no
  authorization decision. Verified: the route calls `root.postRoundToLedger`
  and shapes the result; the non-admin route test asserts `401
  auth.insufficient_role` **and** an untouched stream.
- **Self-read gate (Security ADR §2).** Both reads go through
  `ReadParticipantLedger._gate`, which resolves the participant by id and
  requires `participant.userId == principal.userId`; a missing or foreign id is
  reported **identically** as `401 ledger.participant_not_found` (no
  enumeration/ownership oracle). Route tests assert foreign and unknown both
  surface the same `401` + code.
- **DB backstop (Axiom 6) — layered defence.** The migration: (a) enables RLS on
  `ledger.point_entries`, (b) revokes `insert, update, delete, truncate` from
  `anon, authenticated`, (c) has **no** permissive write policy (all client
  writes denied), (d) grants `select` to `authenticated` gated by a self-read
  policy joining the entry's participant to `auth.uid()`, (e) denies anon all
  select, (f) installs `ledger.reject_entry_mutation` — a `before update or
  delete` trigger that **raises for every role, including the RLS-bypassing
  service role**, so no UPDATE/DELETE can ever complete. Append-only is thus
  enforced physically even against a compromised backend. Verified statement by
  statement.
- **Parameterized SQL.** No SQL is authored in the server layer this session
  (the adapters, unchanged, bind every value via `@named`). The migration
  contains no dynamic user input.

## 3. Correctness

- **Idempotent post (Axiom 4) — no double-credit.** The adapter's
  `ON CONFLICT ON CONSTRAINT point_entries_round_score_uniq DO NOTHING` skips an
  already-present credit and `RETURNING` reports only rows actually inserted; the
  use-case returns that subset verbatim. The migration's
  `point_entries_round_score_uniq` unique constraint is the physical backstop.
  Route test `re-posting … is idempotent` asserts first-post appends one row,
  second-post returns an **empty** `appended_entries`, and the stream still holds
  **exactly one** row. See **L-1** on the constraint's column set.
- **Not-yet-scored refusal.** `PostRoundToLedger` gates on
  `RoundStatus.scored`, returning `ledger.round_not_scored` (invariant → 409)
  otherwise. Route test asserts `409 ledger.round_not_scored` for a `locked`
  round and an untouched stream.
- **Empty round is a legitimate no-op.** A scored round with no scored
  participants posts zero entries (`appendEntries([])` short-circuits `Ok([])`).
  Route test asserts `200` + empty list + empty stream.
- **Balance is a projection (Axiom 5).** The adapter computes `balanceFor` by
  reducing `listEntries` through the pure domain `LedgerBalance.project` — never
  a stored mutable total. Route test asserts `balance == 7`, `entry_count == 2`
  for two credits (4 + 3), and `0 / 0` for an owner with no entries. The
  migration additionally provides a documented `ledger.participant_balances`
  **view** (`SUM(amount)`, `count(*)`) whose value equals the same projection —
  a queryable mirror, not the source the adapter reads (see §4, §6).
- **Stream order.** `listEntries` orders `occurred_at ASC, id ASC`, backed by
  the composite index `point_entries_participant_stream_idx (participant_id,
  occurred_at, id)`; the in-memory harness repo mirrors that order and the
  entries route test seeds out-of-order and asserts ascending-by-instant output.
- **`occurred_at` UTC + provenance.** `PointEntry.create` enforces
  `isUtc` and non-empty `sourceRef`; the mapper emits `occurredAt.toUtc()
  .toIso8601String()`; the migration's `point_entries_source_ref_nonempty`
  check is the backstop.

## 4. Performance

- **Per-participant read is bounded** by a participant's own round
  participation; `balanceFor` reducing `listEntries` is cheap at this scale and
  is index-backed. A future scale phase MAY back the balance with the materialized
  `ledger.participant_balances` view, but only if it provably equals the domain
  reduction — the view is defined identically (`COALESCE(SUM(amount),0)`), so the
  invariant is already documented and testable. **P-note (Info, deferred):** the
  post loops one INSERT per participant inside one transaction (no multi-row
  batch); fine at current scale, mirrors the Scoring adapter's documented P-1.
- The post is a single transaction; a mid-write failure rolls the whole batch
  back (append-only stream never half-written — Axiom 5).

## 5. Maintainability

- The mapper centralizes every ledger wire shape once (`pointEntryToDto` reused
  by all three response shapers), mirroring `scoring_dto_mapper.dart`.
- The routes are thin: method-guard → read root + principal → call use-case →
  `switch` on `Result` → `Response.json` / `errorResponse`. Identical shape to
  the scoring routes.
- The `/participants` subtree gets its own `_middleware.dart` applying
  `bearerAuth()`, mirroring `/rounds` and `/seasons`; the self-read ownership
  gate stays in the use-case (the middleware only authenticates).
- **M-note (Info):** the two RLS-style self-read joins (the balance view relies
  on the base table's policy; the base policy joins `competition.participants`
  to `auth.uid()`) follow the scoring migration's per-table-policy style — no
  `security definer` helper, keeping the attack surface minimal.

## 6. Production-readiness

- **No placeholders / TODOs / mocks** in shipped code (grep-clean across the new
  files). The in-memory repos live under `test/` only.
- **Forward-only, idempotent migration** — every statement guarded (`create …
  if not exists` / `create or replace` / `drop … if exists` / enum + view guards);
  reuses `identity.set_updated_at` from 0001; `security_invoker` on the view is
  applied defensively inside a `do $$ … exception … null` block so an older
  server (pre-PG15) still relies on the base-table grants/RLS.
- **No new external dependency** (§3 confirms: pure reuse of `postgres 3.5.12`
  incl. `runInTransaction`, `dart_frog 1.2.6`, `mocktail`). Environment note
  unchanged: sandbox has no Dart toolchain — verification is by-construction +
  version-checking; "compiles & goes green" is confirmed on a Dart 3.12+ machine
  via `melos bootstrap && melos run verify`.
- **CompositionRoot** wires both use-cases in `bootstrap` (real Postgres
  adapters) and supplies loud `_absent*` stand-ins backed by
  `_UnwiredLedgerRepository` / `_UnwiredParticipantReader` (every method throws
  `StateError`) in `forTesting`, so a route test reaching an unwired ledger slice
  fails loudly. Verified.

---

## 7. Summary of findings

| ID | Severity | Area | Status |
|---|---|---|---|
| L-1 | Low | Correctness/Migration — dedupe key column set | **Refined & documented; idempotency guarantee preserved** (see below) |
| P-note | Info | Performance — per-participant sequential inserts | Recorded; optimize only if a future scale phase shows it hot |
| M-note | Info | Maintainability — self-read join style | Intentional; matches scoring migration; no change |
| S-verified | Info | Security — append-only enforced for every role (trigger + revoke + RLS) | Verified OK; no change |
| C-verified | Info | Correctness — idempotent replay = empty append, one row | Verified OK by route + adapter tests; no change |

### L-1 (Low) — dedupe key column set, resolved

The ratified §2/§4 text names the natural dedupe key as `(participant_id,
round_id, entry_kind)`. The infrastructure adapter (delivered a prior session,
frozen) uses `ON CONFLICT ON CONSTRAINT point_entries_round_score_uniq`. Two
facts force a precise realization of that key in the migration:

1. `ON CONFLICT ON CONSTRAINT` requires a **named constraint**, not a partial
   index (Postgres rejects a partial unique index there). So the dedupe must be
   a plain `UNIQUE` constraint.
2. A plain `UNIQUE (participant_id, round_id, entry_kind)` would also forbid a
   **second `correction`** for the same `(participant, round)` — contradicting
   the ratified rule that a `correction` is **append-many** (each carries its
   own distinct `source_ref`; EntryKind.isDedupedPerRound is `false` for
   `correction`).

**Resolution (this migration):** the constraint is
`UNIQUE (participant_id, round_id, entry_kind, source_ref)`. This preserves the
ratified guarantee exactly:

- For a `round_score` credit the adapter always sets the deterministic
  `source_ref = round_score:{round}:{participant}` (verified in
  `post_round_to_ledger.dart`), so a re-post collides on the identical
  4-tuple → `DO NOTHING` skips → **never a double-credit** (Axiom 4). The
  dedupe is, for a credit, functionally on `(participant, round, round_score)`
  as ratified, because `source_ref` is a pure function of `(round,
  participant)` for that kind.
- A `correction` carries a distinct `source_ref` per entry, so multiple
  corrections for the same `(participant, round)` coexist (append-many) — the
  behaviour the ratified design requires — under the same named constraint the
  adapter references.

No adapter change was needed (it references the constraint by name and sets the
deterministic source_ref). The design note in §2/§4 is updated to state the
realized key precisely. Severity Low because the observable idempotency
behaviour is exactly the ratified one; this is a documentation-precision fix,
not a behavioural change.

---

## 8. Exit criterion

Ledger delivered end-to-end: a scored round is posted to the append-only ledger
by an admin (server-only amounts, idempotent, no double-credit); a participant
reads only their own projected balance and immutable entry stream. Axioms
2/4/5/6 honoured physically (append-only table with revoked UPDATE/DELETE + an
all-role immutability trigger, unique dedupe key, balance-as-projection view,
self-read RLS, anon denied). No new external dependency; `tooling/import_lint`
unchanged. Six-way review GREEN, the single Low finding resolved in-place. Ready
to advance to **Leaderboards** (next phase per Roadmap ADR 0008).
