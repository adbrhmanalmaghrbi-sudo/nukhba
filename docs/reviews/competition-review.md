# Competition Phase — Six-Way Review

_Phase: Competition (immediately after Authentication, per Roadmap ADR 0008)._
_Reviewed: 2026-07-10. Rigor level: Milestone-0 (production-ready, no
placeholders, version-verified, ADR-conformant)._

This document is the mandatory end-of-phase review required by the roadmap: six
independent lenses (architecture, security, correctness/bugs, performance,
maintainability, production-readiness). Every issue found is recorded with its
resolution; nothing is left open at phase exit.

---

## 0. Scope Under Review

| Layer | Files reviewed |
|---|---|
| Domain (`packages/domain/competition`) | `competition_id.dart`, `season_id.dart`, `round_id.dart`, `participant_id.dart`, `format_type.dart`, `competition_visibility.dart`, `round_status.dart`, `participant_status.dart`, `fixture_ref.dart`, `ruleset_snapshot.dart`, `competition.dart`, `competition_season.dart`, `round.dart`, `round_fixture.dart`, `participant.dart` |
| Contracts (`packages/contracts`) | `competition_dto.dart` (`CompetitionDto`, `SeasonDto`, `RoundDto`, `ParticipantDto`, `RoundFixtureDto`) |
| Application (`packages/application/competition`) | `ports/competition_repository.dart`, `ports/ruleset_provider.dart`, `create_competition.dart`, `start_season.dart`, `open_round.dart`, `lock_round.dart`, `link_fixture_to_round.dart`, `join_competition.dart`; shared `common/id_generator.dart`, `common/clock.dart` |
| Infrastructure (`packages/infrastructure`) | `competition/postgres_competition_repository.dart`, `competition/configured_ruleset_provider.dart`, `common/uuid_id_generator.dart`, `common/system_clock.dart` |
| Edge (`apps/server`) | `composition/composition_root.dart`, `http/json_body.dart`, `http/error_envelope.dart`, `routes/competitions/{_middleware,index}.dart`, `routes/competitions/[id]/seasons/index.dart`, `routes/seasons/{_middleware}.dart`, `routes/seasons/[id]/rounds/index.dart`, `routes/seasons/[id]/participants/index.dart`, `routes/rounds/{_middleware}.dart`, `routes/rounds/[id]/lock/index.dart`, `routes/rounds/[id]/fixtures/index.dart` |
| Migration | `supabase/migrations/0002_competition.sql` |
| Tests | domain (7 files), contracts (`competition_dto_test.dart`), application (6 use-case tests + `fakes.dart` + `fake_competition_repository.dart`), infrastructure (`postgres_competition_repository_test.dart` + `_integration_test.dart`), edge (`competition_route_harness.dart`, `competitions_index_test.dart`, `competition_seasons_test.dart`, `season_rounds_test.dart`, `season_participants_test.dart`) |

**End-to-end flows proven (edge → use-case → domain → port → adapter):**

- `POST /competitions` → `bearerAuth` → `CreateCompetition` (admin) →
  `Competition.create` → `saveCompetition` → `CompetitionDto` (`201`).
- `POST /competitions/{id}/seasons` → `StartSeason` (admin, existence
  precondition) → `CompetitionSeason.create` → `saveSeason` → `SeasonDto`.
- `POST /seasons/{id}/rounds` → `OpenRound` (admin) → `RulesetProvider`
  freeze → `Round.open` → `saveRound` → `RoundDto`.
- `POST /rounds/{id}/lock` → `LockRound` (admin) → `Round.transitionTo` →
  guarded `updateRoundStatus` (optimistic concurrency) → `RoundDto`.
- `POST /rounds/{id}/fixtures` → `LinkFixtureToRound` (admin, round-open
  invariant) → `RoundFixture.create` → `saveRoundFixture` → `RoundFixtureDto`.
- `POST /seasons/{id}/participants` → `JoinCompetition` (any authenticated
  user, principal-not-body) → idempotent → `Participant.join` →
  `saveParticipant` → `ParticipantDto`.

---

## 1. Architecture Review

**Verdict: PASS.**

- **Clean-Architecture dependency rule holds (ADR 0007 §1).** Domain imports
  only `shared`; contracts import nothing (`library;`); application imports
  `domain` + `shared` and touches infrastructure **only through the ports**
  `CompetitionRepository` / `RulesetProvider`; infrastructure implements those
  ports; `server` is the sole component importing `infrastructure` (the
  composition root). `tooling/import_lint`'s `allowedDependencies` map already
  covers all six packages — **no new internal package appeared**, so the ruleset
  is unchanged (as the phase constraints require).
- **Aggregate boundaries respected (Database ADR §1/§3).** `Competition →
  CompetitionSeason → Round` with `RoundFixture` inside the boundary; the
  round carries its frozen `RulesetSnapshot`. `Participant` is a *separate*
  aggregate root (its own id, its own table, referenced by season + user) — the
  scale boundary that keeps high-volume prediction/ledger writes from locking
  Competition.
- **Axiom 3 (football seam) is physical.** A fixture is named only via
  `RoundFixture`/`FixtureRef` (a typed id), never pulled into the aggregate;
  the migration deliberately has **no** FK from `round_fixtures.fixture_id` to a
  fixtures table (that table is a later phase; adding the FK then is
  forward-only/expand-only) and **no** `competition_id` on any fixture.
- **Axiom 4 (predict once, rank everywhere).** `Round` carries no group
  reference; visibility is modelled as a closed enum seam
  (`CompetitionVisibility`) so group-scoping can arrive later without a schema
  change.
- **Game-Engine seam (Application ADR §2.10).** `FormatType` is a discriminator,
  not a table-per-format; `RulesetProvider` is the seam to the future Scoring
  context — today `ConfiguredRulesetProvider` supplies a real, versioned default
  and is swappable at the composition root with **no** use-case change.
- **Command/query separation & use-case API (API ADR §2/§4).** Every route is a
  domain intent (`/rounds/{id}/lock` as a sub-resource command, not a status
  PATCH); DTOs are schema-decoupled and versioned.

No architectural deviations. No ADR change requested.

---

## 2. Security Review

**Verdict: PASS (one documented, deliberate design note; no action).**

- **Two-layer authorization (Security ADR §2).** Layer 1 = `bearerAuth`
  middleware scoped per-subtree (`/competitions`, `/seasons`, `/rounds`), never
  global — `/health` stays public. Layer 2 = per-use-case
  `Authorization.requireRole`: admin for create/start-season/open-round/lock/
  link-fixture; `user` for join.
- **Principal, not body, is the source of identity (Security ADR §2).**
  `JoinCompetition` takes `userId` from the verified `AuthenticatedUser`, never
  from the request body — a caller can never enrol someone else. Verified by
  `season_participants_test.dart` ("the enrolled user is taken from the verified
  token").
- **SQL injection impossible.** Every query in
  `PostgresCompetitionRepository` binds through `@named` parameters; enum tokens
  are cast server-side (`@x::competition.<enum>`); no untrusted value is ever
  concatenated.
- **Defense in depth — DB is the last line (Axiom 6 / Database ADR §10).** RLS is
  enabled on all five tables with **no write policy** (all client writes denied)
  plus explicit `revoke insert,update,delete,truncate from anon, authenticated`;
  client reads are narrow (`competitions` public-only, seasons/rounds/fixtures
  join through to public visibility, `participants` self-only via
  `auth.uid()`); anon gets `using (false)`. The backend uses the service role
  and bypasses RLS, bearing full invariant responsibility — matching the trust
  zones.
- **Write-once ruleset & lifecycle enforced at the DB too.** Triggers
  `rounds_freeze_ruleset` (rejects any change to `ruleset_snapshot`/
  `ruleset_version`) and `rounds_enforce_lifecycle` (rejects any non
  `open→locked→scored` move) are the backstop to the domain checks; both raise
  `check_violation` (`23514`), which the adapter reclassifies to
  `ErrorKind.invariant`.
- **Error hygiene.** `error_envelope.dart` serializes only `code` + safe
  `message`; `AppError.cause` (server-only detail) never crosses the wire.

**Design note (no action — ratified in the Authentication phase).**
`ErrorKind.authorization` maps to **401** in `error_envelope.dart`, so an
authenticated-but-insufficiently-privileged caller (non-admin hitting an
admin-only command) also receives 401 rather than a 403. This is a consequence
of the closed four-class `ErrorKind` set (no distinct "forbidden" class), a
decision already made and reviewed in the Authentication phase. It is
information-safe (it does not leak resource existence) and consistent across the
whole surface. Splitting authentication (401) from authorization (403) would
require adding an `ErrorKind` value — an architecture change gated on approval
per Roadmap ADR — so it is **recorded, not changed** here.

---

## 3. Correctness / Bug Review

**Verdict: PASS after two fixes (both applied in this review).**

### C-1 (bug, FIXED) — broken test scaffolding in `season_participants_test.dart`

The "a non-POST method is 405" test passed its method via a bogus
`extension type HttpMethodGet` whose `value` getter dispatched through a long
chain of no-op getters terminating in `throw UnimplementedError()`. Invoking it
would have thrown at runtime instead of yielding a GET method — the test was
either dead or failing, and the construct was meaningless code that a six-way
review must not ship.

**Resolution:** replaced `method: HttpMethodGet.value` with the direct
`method: HttpMethod.get` (the harness's `wireContext` already accepts an
`HttpMethod`, and every other route test uses `HttpMethod.get` this way — e.g.
`competitions_index_test.dart:107`), and deleted the entire bogus
`extension type` block and its misleading "avoid the dart_frog import" comment
(the file already imports `package:dart_frog/dart_frog.dart`). Braces/parens
re-verified balanced; no `HttpMethodGet` reference remains.

### C-2 (documentation/API mismatch, FIXED) — join idempotency status code

The `POST /seasons/{id}/participants` handler doc-comment claimed a repeated
join "returns the existing enrolment (`200`) … a first-time join returns `201`",
but the handler returns `201` unconditionally. `JoinCompetition` returns only
the resulting `Participant`, not whether *this* call created the row, so the edge
cannot distinguish created-now from already-present.

**Resolution:** corrected the doc-comment to describe the actual, correct
behaviour — the command is idempotent (a retry converges on the one enrolment
and returns it; no duplicate, no error), and the status is `201` in both cases
because the use-case contract intentionally does not leak a created/existing
flag through the port. Returning `201` for an idempotent retry that observes the
same resource is safe. Distinguishing 200/201 would require widening the
use-case return contract; that is a deliberate non-goal, so only the
documentation was aligned to the code. The idempotency behaviour itself is
covered by the "a repeat join returns the existing enrolment" test
(asserts one participant row and the same id).

### Correctness spot-checks that PASSED

- **Ruleset freeze is total.** `Round` is born `open` with an immutable snapshot;
  there is no API to replace it; `transitionTo` carries the snapshot through
  unchanged; `RulesetSnapshot` deep-copies into unmodifiable collections and
  exposes an unmodifiable view (deep `==`/`hashCode` are order-independent for
  maps). The DB trigger is the backstop.
- **Linear lifecycle.** `RoundStatus.canTransitionTo` permits only
  `open→locked` and `locked→scored`; self-transitions and backward/skipping
  moves are rejected as `ErrorKind.invariant`. The DB trigger mirrors exactly
  the same edges.
- **Optimistic concurrency on lock.** `updateRoundStatus` is a guarded
  `UPDATE … WHERE id=@id AND status=@expected RETURNING id`; zero rows updated →
  `competition.round_transition_conflict`. Two concurrent locks cannot both win.
- **Join race convergence.** On a unique-violation
  (`competition.already_joined`) the use-case re-reads and returns the winning
  enrolment, so a lost race still yields a successful idempotent result.
- **Adapter constraint-name mapping matches the migration exactly.** Every name
  the adapter switches on (`competitions_pkey`, `seasons_competition_id_fkey`,
  `rounds_season_sequence_uniq`, `rounds_season_id_fkey`,
  `round_fixtures_pkey`, `round_fixtures_round_id_fkey`,
  `participants_season_user_uniq`, `participants_pkey`,
  `participants_season_id_fkey`, `participants_user_id_fkey`) is a real
  constraint in `0002_competition.sql`. Trigger-raised `check_violation`s carry
  no constraint name and fall through to `competition.integrity_violation`,
  exactly as documented.
- **Row-mapping is total & defensive.** Every `_map*` re-parses stored values
  through the domain `tryParse`/`create` gates and maps any drift to a
  transient `*.row_corrupt` (not blamed on the caller). Timestamps normalized to
  UTC; JSONB read as `Map` or defensively decoded from text.
- **No placeholders / TODO / UnimplementedError anywhere in shipped code**
  (grep-verified across `packages/` and `apps/server/{lib,routes}`).

---

## 4. Performance Review

**Verdict: PASS.**

- **Indexes match access paths.** `seasons(competition_id)`,
  `rounds(season_id)`, `round_fixtures(fixture_id)`,
  `participants(season_id)`, `participants(user_id)`, plus the unique
  constraints (`rounds(season_id,sequence)`, `round_fixtures(round_id,
  fixture_id)` PK, `participants(season_id,user_id)`) back both the FKs and the
  repository lookups (`findSeason`/`findRound`/`findParticipant`). No unindexed
  scan on a hot path.
- **Aggregate scale boundary honoured.** `Participant` is separate from
  Competition (Database ADR §1), so future high-volume prediction/ledger writes
  never contend on the Competition aggregate.
- **Single-statement writes.** Each command is one `INSERT`/guarded `UPDATE`; no
  N+1, no read-modify-write loop. Lock uses a single conditional UPDATE rather
  than SELECT-then-UPDATE.
- **Connection reuse.** All adapters share the one pooled `PostgresConnection`
  from the composition root; `bootstrap` caches the *future* so concurrent first
  callers don't open multiple pools.
- **RLS read policies** use `exists (… where … visibility='public')` sub-selects
  joining on primary keys — index-friendly; they constrain only the client
  surface (the service-role backend bypasses RLS).

---

## 5. Maintainability Review

**Verdict: PASS (one minor, non-blocking note).**

- **Illegal states unrepresentable.** Typed ids (no primitive obsession),
  closed enums with explicit `wireValue` (decoupled from Dart identifiers) and
  total `tryParse`, `Result`-returning factories — the compiler and the type
  system carry the invariants.
- **Single definition of each rule.** The lifecycle machine lives once in
  `RoundStatus`; role hierarchy once in `AuthenticatedUser.hasRole`; the
  `ErrorKind→status` map once in `error_envelope.dart`; the DI graph once in
  `CompositionRoot`.
- **Wire tokens are the single source of truth end to end** — the migration's
  enum literals (`football_scoreline`, `public`/`private`, `open`/`locked`/
  `scored`, `active`/`withdrawn`) match the domain `wireValue`s exactly, so the
  adapter stores and reads the same strings the domain parses.
- **Tests document behaviour** at every layer (~3.2k lines), and `forTesting`
  wires only the exercised slice with loud "unwired" stand-ins.
- **Minor note (recorded, not blocking):** the canonical UUID `RegExp` is
  defined as a shared top-level `uuidPattern` in `competition_id.dart` and reused
  by the season/round/participant ids, but `fixture_ref.dart` declares its own
  private `_uuid` copy of the same pattern. Harmless duplication; a future tidy
  could have `FixtureRef` reuse `uuidPattern` too. Left as-is to avoid churn at
  phase exit.

---

## 6. Production-Readiness Review

**Verdict: PASS.**

- **Fail-fast bootstrap.** `CompositionRoot.bootstrap` validates
  `PostgresConfig`/`AuthConfig` and opens the connection eagerly, throwing a
  fatal `StateError` on misconfig so the process refuses to start broken.
  `dispose` closes the JWKS client and connection.
- **No placeholder infrastructure.** `ConfiguredRulesetProvider` is a real,
  complete, versioned adapter (not a mock/TODO) that satisfies the
  `RulesetProvider` contract for the one format that exists today and is
  swappable when Scoring ships.
- **Migration is forward-only, expand-only, idempotent/re-runnable** — every
  statement guarded (`if not exists` / `create or replace` / `drop … if
  exists`); reuses `identity.set_updated_at` from migration 0001; safe to apply
  repeatedly.
- **Integration tests gated correctly.** The behaviours a hermetic test cannot
  cover (mapping a real `postgres` `ServerException`'s violated-constraint name,
  and the trigger `check_violation` backstop) are enumerated in
  `postgres_competition_repository_integration_test.dart`, tagged `integration`,
  and excluded from the hermetic `melos run test` — run in CI's dedicated
  integration job against an ephemeral Postgres with the migrations applied.
- **Uniform, information-safe error surface**; typed retryability
  (`transient` only) preserved end to end.

---

## 7. Version-Verification (this phase)

No new external library or API was introduced in the Competition phase. The
adapter relies only on `postgres 3.5.x` facts already verified in Milestone 0
(§3 of the project context): `ServerException` carries the SQLSTATE `code` and
`constraintName`; the specialized `UniqueViolationException` /
`ForeignKeyViolationException` subtypes are `ServerException`s (so matching the
base type covers them); `@named` parameter binding and server-side enum casts.
Integrity SQLSTATEs used: `23505` (unique_violation), `23503`
(foreign_key_violation), `23514` (check_violation). No new row added to the
version log is required.

---

## 8. Issues Ledger

| ID | Lens | Severity | Status | Resolution |
|---|---|---|---|---|
| C-1 | Correctness | High (broken test) | **Fixed** | Removed bogus `HttpMethodGet` extension-type chain in `season_participants_test.dart`; use `HttpMethod.get` directly. |
| C-2 | Correctness/API | Low (doc vs behaviour) | **Fixed** | Corrected the join handler doc-comment to describe the actual idempotent `201`-in-both-cases behaviour. |
| S-note | Security | Info | Recorded | 401 (not 403) for insufficient-role is a ratified Authentication-phase decision (closed `ErrorKind` set); changing it is ADR-gated. |
| M-note | Maintainability | Info | Recorded | `fixture_ref.dart` duplicates the UUID `RegExp` instead of reusing `uuidPattern`; harmless, left to avoid phase-exit churn. |

**Phase exit: GREEN.** All found defects fixed; no open blocking issues. The
Competition phase is complete at Milestone-0 rigor. Next phase per Roadmap ADR
0008: **Prediction Engine.**

---

## Addendum — BLOCKER FA-1 read-surface patch (2026-07-13)

_This addendum is appended per the ratified BLOCKER FA-1 resolution (see
`docs/project-context.md` §4, "BLOCKER FA-1"). The original GREEN verdict above
is NOT reopened or rewritten — this paragraph only records a strictly additive
read-layer completion made during the Flutter App phase (12/12) so the client's
Competition-browse scope became buildable._

During the Flutter App phase it was found that the Competition context shipped
only command (write) and single-id internal reads — there was no client-facing
*browse* surface, so the ratified Core client items "Competition (browse)" and
the read half of "Prediction (submit)" (rendering the open round + its fixtures)
were not buildable. The ratified resolution (Option A) added a strictly
additive, read-only patch — **no existing write use-case, POST branch, domain
rule, migration, or DTO shape was changed**:

- New read-only repository methods on `CompetitionRepository`
  (`listCompetitions` / `listSeasonRounds` / `listRoundFixtures`) + their
  `PostgresCompetitionRepository` implementation (existing method signatures
  untouched). The three other `implements CompetitionRepository` classes
  (`FakeCompetitionRepository`, the harness `InMemoryCompetitionRepository`, and
  the `_UnwiredCompetitionRepository` stand-in) were updated to match — see
  DEFECT FA-2 in §4 of the project context.
- New query use-cases in `packages/application/competition/`
  (`GetCompetition`, `GetRound`, `ListCompetitions`, `ListSeasonRounds`,
  `ListRoundFixtures`), each `PlatformRole.user`-gated, mirroring the existing
  `GetRoundScores` / `ListRoundPredictions` query pattern, with their own
  application-layer tests.
- New read-only routes / branches: `GET /competitions` (a `_list` branch beside
  the existing `POST`), `GET /competitions/{id}` (new file), `GET /rounds/{id}`
  (new file), and a `GET` branch on `GET /rounds/{id}/fixtures` (beside the
  untouched `POST` command) + `competition_dto_mapper.dart`, all wired into
  `CompositionRoot.bootstrap()`. Covered by route tests
  (`competitions_browse_test.dart`, `rounds_browse_test.dart`) and the corrected
  `competitions_index_test.dart` (its stale "GET is 405" case was replaced once
  GET became the browse-list branch).

This closes the Competition-browse read gap for client consumption. It does not
alter any conclusion of the original six-way review; the phase remains **GREEN**.

---

## Addendum — DEFECT AD-2 season/round browse-navigation closure (2026-07-13)

_This second addendum is appended per the ratified BLOCKER FA-1 resolution
discipline (see `docs/project-context.md` §4). As with the first addendum, the
original GREEN verdict above is NOT reopened or rewritten — this paragraph only
records the strictly additive fourth extension of the same read-layer patch,
made during the Flutter App phase (12/12), that closed the last
browse-navigation gap on the way from a competition down to a round's fixtures._

The first addendum's read surface (`listCompetitions` / `listSeasonRounds` /
`listRoundFixtures` + `GetCompetition`/`GetRound`) let a client list every
competition, open one, and — given a season id — list that season's rounds and a
round's fixtures. It left ONE navigation hop unbuilt: from a chosen competition
to **its own seasons**, so a client had no way to discover the `seasonId` it
needed before it could list rounds. DEFECT AD-2 tracked closing that hop, again
strictly additively — **no existing write use-case, POST branch, domain rule,
migration, or DTO shape was changed**:

- A new read-only repository method `listCompetitionSeasons` ADDED to
  `CompetitionRepository` + its real `PostgresCompetitionRepository`
  implementation (`SELECT id, competition_id, label FROM competition.seasons
  WHERE competition_id = @competition_id ORDER BY label ASC, id ASC`, reusing the
  existing `_mapSeason`/`_mapAll` helpers). The three other `implements
  CompetitionRepository` classes (`FakeCompetitionRepository`, the harness
  `InMemoryCompetitionRepository`, and the `_UnwiredCompetitionRepository`
  stand-in) were updated to match, keeping all four implementers in lockstep as
  DEFECT FA-2 required.
- A new query use-case `ListCompetitionSeasons` in
  `packages/application/competition/` (`PlatformRole.user`-gated, read-only,
  mirroring the existing `ListSeasonRounds`/`ListRoundFixtures` query pattern)
  with its own application-layer test, and wired into `CompositionRoot.bootstrap()`
  (`listCompetitionSeasons: ListCompetitionSeasons(repository:
  competitionRepository)`) with a matching `forTesting` optional param +
  `_absentListCompetitionSeasons()` stand-in.
- The GET route branches completing the two-hop path:
  `GET /competitions/{id}/seasons` and `GET /seasons/{id}/rounds` (each a `_list`
  branch beside the untouched `POST` command), covered by route tests
  (`competition_seasons_test.dart`, `season_rounds_test.dart`,
  `seasons_rounds_browse_test.dart`).
- `packages/api_client` accordingly exposes the complete six-method
  `CompetitionApi` surface (`listCompetitions`, `getCompetition`,
  `listCompetitionSeasons`, `listSeasonRounds`, `listRoundFixtures`,
  `getRound`), each with success / not-found / malformed-JSON coverage in
  `competition_api_test.dart`.

With this, a client can traverse the full read chain competition → seasons →
rounds → fixtures without any missing hop, making the ratified Core scope items
"Competition (browse)" and the read half of "Prediction (submit)" fully
buildable. As with the first addendum, this does not alter any conclusion of the
original six-way review; the phase remains **GREEN**.
