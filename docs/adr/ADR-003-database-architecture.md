# ADR-003 — Database Architecture

**Nukhba Platform · Architectural Decision Record**
Status: **Accepted** · Version 1.0 · Date: 2026-07-08
Depends on: ADR-001 Domain Architecture (Accepted) · ADR-002 Application Architecture (Accepted)
Governs: ADR-004 API, ADR-005 Event, ADR-006 Security, ADR-007 Deployment

> This ADR defines the *physical shape of truth*. It does not contain SQL DDL, RLS policy
> expressions, trigger bodies, or migration scripts — those are implementation artifacts produced
> later against this decision.

---

## 1. Context

ADR-001 defined *what the system is*; ADR-002 defined *how the code protects it*. This layer defines
*how the data is stored so that the invariants are enforced by the database itself, not merely by the
application above it.*

One principle governs everything, inherited from Axiom 6: **the database is the last line of defense
for integrity, not the first.** The application layer enforces business invariants, but the database
must make the *most catastrophic* violations physically impossible — you cannot delete a ledger
entry, you cannot store a point balance that disagrees with its entries, you cannot write to a Tier-1
table as a client. Where the application says "should not," the database says "cannot." That
redundancy is deliberate and is the whole point of this layer.

Second framing: this is a Postgres schema on Supabase, designed as a Postgres schema *first*. We use
Supabase-specific features (RLS, Realtime, Auth linkage) where they serve us, but never let a
Supabase convenience compromise a domain invariant.

## 2. Decision

### 2.1 Aggregate boundaries

An aggregate is a cluster of entities that must be transactionally consistent together and is
modified as a unit through a single root. Aggregate boundaries determine transaction boundaries.

- **Identity aggregate.** Root `User`; members: sessions, devices. A session cannot exist without its
  user. `Profile` is a *separate* aggregate (ADR-001 separated identity from profile), referenced by
  user id but independently modifiable.
- **Community aggregate.** Root `Group`; members: memberships, invitations. A membership cannot exist
  without its group; role changes and join/leave are transactionally consistent within the group.
  Tier-1 because membership drives audience filtering.
- **Football Data — two separate aggregates.** `Fixture` (root, with schedule) and `FixtureResult`
  as its own aggregate referencing the fixture. They are *not* one aggregate because a correction is
  a new `FixtureResult` superseding the old — treating results as an independent aggregate makes that
  natural. `Team`, `Tournament`, `TournamentEdition` are slowly-changing reference aggregates, each
  its own small root.
- **Competition aggregate.** Root `Competition` → `CompetitionSeason` → `Round`. Members within the
  boundary: `RoundFixture` links and the round's frozen `ruleset_snapshot`. A round belongs to
  exactly one season; the snapshot is written once at lock and never mutated.
- **Participant and Prediction are separate aggregates from Competition** — the critical boundary
  decision. Millions of predictions must not require locking the competition aggregate. Prediction
  writes stay independent and highly concurrent: thousands of users predicting the same round touch
  thousands of independent prediction rows, never a shared competition row.
- **Ledger aggregate.** Root: the `PointEntry` stream for a `(participant, season)`. The aggregate is
  the *append-only sequence*; the derived balance is a projection, not part of the write aggregate.
- **Engagement, Social, Notification** — projection/peripheral aggregates: rebuildable, never sources
  of truth.

Overarching rule (tracing to ADR-002's outbox): **a single use-case transaction modifies exactly one
aggregate plus the outbox.** Cross-aggregate effects happen through events, never through a
transaction spanning two roots.

### 2.2 Entity ownership and table responsibilities

Each table is owned by exactly one bounded context. No table is shared; cross-context references are
by id only; a context never writes to another context's tables. This is the physical expression of
ADR-002's "no context imports another context's repositories."

- **Identity & Access** owns user, credential, session, device tables + platform-role assignment.
  Links to Supabase Auth identity but keeps its own canonical user row.
- **Community** owns group, membership, invitation tables. Membership is the pivotal table of the
  whole read model — the physical source of every audience filter.
- **Football Data** owns team, tournament, tournament-edition, fixture, fixture-result tables + the
  ACL external-identity mapping table. The fixture table carries **no competition reference** —
  enforced by simply not having the column, making the universal-fact rule structurally true.
- **Competition** owns competition, season, round, round-fixture link, participant tables. The round
  table carries the frozen ruleset snapshot as a structured column. The round-fixture table is the
  many-to-many join enabling predict-once (Axiom 4).
- **Scoring** owns ruleset and scoring-definition tables — rules as data, not code. Referenced by
  competitions and copied (snapshotted) into rounds.
- **Ledger** owns the point-entry table (append-only truth) and the balance projection table
  (derived).
- **Engagement** owns leaderboard, streak, achievement, hall-of-fame projection tables — all
  rebuildable.
- **Social** and **Notification** own their respective Tier-3 tables.
- **Infrastructure/platform** owns the outbox table and the projection-checkpoint tables that track
  rebuild positions.

### 2.3 Relationships

The relationship map from ADR-001, expressed as foreign-key intent.

- **Central chain:** `Fixture` ← referenced by → `RoundFixture` → belongs to `Round` → belongs to
  `CompetitionSeason` → belongs to `Competition`. A `Prediction` references exactly one
  `RoundFixture` and one `Participant`. A `Participant` references one `User` and one
  `CompetitionSeason`.
- **Audience side:** `Group` ← `Membership` → `User`. A leaderboard view is computed by joining
  Ledger balances for participants whose users are in a given group's membership set — the *(audience
  × competition)* pair realized as a join between Community and Ledger, mediated by Participant.
- **Truth side:** `FixtureResult` references `Fixture`. `PointEntry` references `Participant` and
  `CompetitionSeason`, and carries `source_ref` pointing to the `Prediction` (or admin action) that
  caused it — the audit trail.

Two relationships are deliberately **absent**, and their absence is load-bearing: **Prediction has
no group reference** (Axiom 4) and **Fixture has no competition reference** (Axiom 3). These
non-relationships are as architecturally important as the relationships.

Referential actions favor **restriction over cascade** for Tier-1 data: you cannot delete a fixture
that has results, cannot delete a participant that has ledger entries. Truth is not
cascade-deletable. Tier-3 data may cascade freely.

### 2.4 Constraints — where invariants become physical

Each ADR-001 invariant maps to a physical constraint.

- **Append-only ledger** — enforced by *revoking UPDATE and DELETE at the table-permission level*
  for all roles including the service role, plus a trigger that rejects any attempt regardless. The
  only permitted operation on `point_entry` is INSERT. The vocabulary to violate append-only does
  not exist at the database level, mirroring the repository interface (ADR-002 §2.9).
- **Balance equals sum** — the balance table is a *projection only*, never authoritatively
  hand-written, plus a reconciliation check (scheduled verification, optionally a constraint-trigger)
  asserting `balance = SUM(entries)` and alarming on drift. The balance is a cache of a computation;
  the computation is the truth.
- **Prediction immutable after deadline** — a trigger compares the referenced round's deadline to
  the current time on any UPDATE and rejects mutations after lock. The application checks first; the
  database guarantees it.
- **Frozen ruleset** — the round's `ruleset_snapshot` column is write-once: a trigger rejects any
  UPDATE once the round status has left the open state.
- **One official result** — a partial unique constraint ensures at most one *active* (non-superseded)
  result per fixture; corrections insert a new active result and mark the prior superseded in a
  single transaction.
- **Prediction uniqueness** — a unique constraint on `(participant, round_fixture)`.
- **Universal fact** — enforced structurally by the *absence* of a competition column on fixtures.

Determinism of scoring is a domain-code property (ADR-002), not a database constraint; the database
supports it by storing rulesets and snapshots immutably so replay is reproducible.

### 2.5 Indexing strategy

Indexes are designed around the two dominant access patterns: **high-concurrency prediction writes**
and **audience-scoped leaderboard reads**.

- **Prediction writes:** the unique index on `(participant, round_fixture)` doubles as the write-path
  lookup. Index on `(round_fixture)` supports "score all predictions for this fixture" at
  finalization. Index on `(participant)` supports a user viewing their own predictions.
- **Leaderboard reads (performance-critical):** balance projection indexed on
  `(season, current_total DESC)` for the global leaderboard; membership indexed on `(group, user)`
  and `(user, group)` so audience filtering resolves quickly in both directions. The *(audience ×
  competition)* join is the hottest read; its supporting indexes on membership and balance are the
  most important non-key indexes in the system.
- **Ledger:** index on `(participant, season, created_at)` supports balance recomputation and
  chronological audit/history.
- **Outbox:** index on `(status, created_at)` supports dispatcher polling for unpublished events.
- **Football data:** fixture `(edition, scheduled_time)` for schedule queries; ACL external-id
  mapping on `(source, external_id)` for identity resolution.

Discipline note: index for *known* access patterns from the ADRs, not speculatively. Every index
costs writes, and prediction writes are our highest-volume operation — so we resist over-indexing the
prediction and ledger tables.

### 2.6 Partitioning strategy

Partitioning is an infrastructure-scaling concern (ADR-001: infrastructure scales, domain doesn't).
The *schema* is designed to make partitioning possible without domain changes; actual partitioning
is deferred until volume justifies it.

The two tables that grow unbounded are `point_entry` (ledger) and `prediction`. Both are naturally
partitionable by **season** (or a time dimension derived from it), because access is almost always
season-scoped. Carrying a season discriminator from day one lets us convert them to partitioned
tables later as a pure infrastructure migration.

The outbox is partitionable by time and subject to **aggressive archival** — published events older
than a retention window move to cold storage, keeping the hot outbox small for fast polling.

Projection tables (leaderboards, streaks) are not partitioned; they are bounded by participant count
per season and cheaply rebuildable, so we favor rebuild-and-cache over partitioning them.

*Accepted cost, recorded:* we carry a season/time discriminator on the large tables now even though
it is redundant with foreign keys, purely to keep the partitioning door open. Cheap insurance versus
the expensive alternative of re-sharding a monolithic table under load.

### 2.7 Projection tables and read models

ADR-002's CQRS-lite split becomes concrete: **write models are normalized and integrity-first; read
models are denormalized and speed-first.**

- **Balance projection** stores `(participant, season, current_total, last_entry_position)` — a
  materialized sum of the ledger, updated incrementally as entries append and fully rebuildable at
  any time. `last_entry_position` lets incremental updates resume and lets reconciliation detect
  drift.
- **Leaderboard read model** — the *(audience × competition)* realization, two shapes:
  - **Global leaderboard:** a materialized projection per season ordered by total.
  - **Group leaderboard:** balance-projection rows filtered by the group's membership set.
    **Group leaderboards are computed on read (balance ∩ membership), not pre-materialized per
    group** — because groups are competition-agnostic and numerous (Axiom 5). Per-season balances are
    materialized once; the cheap membership join produces any group's view on demand, cached briefly.

All projection tables carry a rebuild checkpoint so a corrupted or schema-changed projection can be
dropped and rebuilt from the event stream / ledger without touching truth — ADR-001's "projections
are rebuildable" made operational.

### 2.8 Ledger schema

The ledger is the physical seat of Axiom 6.

`point_entry` is append-only and immutable, carrying: an identity, the participant and season, a
signed `amount`, a `reason_type` (prediction_scored / manual_adjust / correction / bonus), a
`source_ref` linking to the causing prediction or admin action, `created_at`, and `created_by`. There
is deliberately **no status column and no way to void an entry** — a reversal is a new compensating
entry with `reason_type = correction` and a negative amount referencing the original via `source_ref`.
History is complete and immutable; current state is always the running sum.

An **entry sequence/position** per `(participant, season)` gives deterministic ordering and supports
incremental projection and gap detection. The ledger is effectively an event-sourced sub-system for
points: the entries *are* the events, and the balance is their fold.

The balance projection (`point_balance`) is the derived read side: current total plus last processed
entry position, rebuildable at will, verified against `SUM(amount)` by a scheduled reconciliation job
that alarms on any mismatch. A mismatch is a Sev-1 integrity incident, never silently corrected.
This eliminates the legacy destructive full-recalc entirely: re-scoring a round appends correction
entries; it never overwrites history.

### 2.9 Event outbox schema

The outbox realizes ADR-002's transactional-outbox guarantee (full mechanics in ADR-005). The
`outbox_event` table carries: an identity, `event_type`, a structured `payload` (self-contained so
consumers need no back-references into other contexts), an `aggregate_ref` for traceability, a
`status` (pending / published / failed), `created_at`, `published_at`, and a retry/attempt counter
with a dead-letter disposition.

Absolute write rule: **every integrity-critical use-case writes its domain change and its outbox
event in the same transaction.** The event exists if and only if the change committed. The dispatcher
polls `(status = pending)` ordered by creation, publishes, and marks published — at-least-once
delivery, so consumers must be **idempotent** (keyed by event id). Idempotency shapes consumer table
design: each consumer keeps a processed-event checkpoint to discard duplicates. Published events are
retained for a window (audit, replay, new-consumer bootstrap) then archived; the outbox is both the
reliable delivery mechanism and a secondary audit log of everything integrity-relevant.

### 2.10 RLS strategy

RLS is defense-in-depth, not the primary boundary (ADR-002; full security treatment in ADR-006).
Tier-differentiated.

- **Tier-1 tables** (predictions, participants, competitions, rounds, ledger, memberships, results):
  RLS **denies all client writes outright** — the client role has no INSERT/UPDATE/DELETE grant. The
  sole writer is the backend service role. Client *reads* are RLS-scoped: a user may read their own
  predictions, leaderboards for competitions they participate in, memberships of groups they belong
  to; the ledger is readable by its owning participant but not client-writable by anyone.
- **Tier-3 tables** (chat, reactions, memes, notification preferences): RLS permits direct client
  access under group-membership and ownership policies, because ADR-002 allows clients to touch
  Tier-3 directly via Supabase for realtime. Here RLS *is* the working boundary.

The membership table is the linchpin of read RLS: nearly every policy asks "is this user a member of
the relevant group / participant of the relevant competition?" So membership and participant lookups
must be fast (§2.5) and policies written to use them efficiently.

*Recorded consequence:* the service role bypasses RLS by design, so the backend is fully trusted and
must itself enforce every business invariant before writing — RLS will not save us from a backend
bug. This is why the Application layer's use-case rigor is non-negotiable (see ADR-006).

### 2.11 Migration strategy from the current system (Strangler Fig)

Each phase ships independently and leaves the system working.

- **Phase 1 — Establish truth tables alongside the old.** Introduce Football Data tables (fixture,
  fixture_result) and the RoundFixture link *next to* the current `matches` table. Backfill by
  splitting each competition-bound match into a universal fixture plus a round-fixture link. The old
  table remains readable during transition; new writes go to the new shape.
- **Phase 2 — Introduce the ledger and stop authoritative balance writes.** Create `point_entry` and
  `point_balance`. Backfill by converting current totals into an initial set of entries (a
  "migration_baseline" entry per participant, then reconstructable history). All point changes become
  appends; the direct-write-to-leaderboard path is disabled. Highest-risk phase, most verification:
  every participant's summed ledger must equal their pre-migration total, checked row by row.
- **Phase 3 — Move scoring server-side and snapshot rulesets.** Extract rulesets into the ruleset
  tables; populate each existing round's frozen snapshot. Scoring runs in the backend against
  snapshots; the browser calculation path is retired.
- **Phase 4 — Introduce outbox and event-driven consumers.** Add the outbox; convert the
  server-side scoring flow to emit events; wire Engagement/Notification as consumers. Projections
  become rebuildable read models.
- **Phase 5 — Community as first-class.** Introduce group/membership/invitation tables; refactor
  leaderboards into the *(audience × competition)* read model. Public competitions use the "everyone"
  audience; private groups become available.

Each phase has an explicit **rollback**: because new tables are introduced alongside old, and Phase 2
verifies the ledger against old totals before cutover, any phase can be paused with the prior system
still authoritative.

### 2.12 Versioning strategy

Two things version, differently.

- **Schema versioning** — forward-only, sequentially-numbered migrations (`supabase/migrations`). No
  destructive migration runs without a paired, tested backfill and a verification step. Column
  removals follow expand-contract: add the new shape, migrate reads/writes, then remove the old only
  after a full release proves the new path — never a big-bang drop.
- **Rule/data versioning** — domain-level, the reason the frozen snapshot exists. Rulesets carry a
  `version`; competitions reference a ruleset version; rounds copy a full immutable snapshot at lock.
  Editing a ruleset creates a new version and never alters historical rounds. A round records which
  engine/format produced it, so future engine changes cannot retroactively reinterpret old
  predictions.
- **Event schemas** are versioned too: each `event_type` carries a schema version in its payload so
  consumers can evolve without breaking on old archived events during replay (see ADR-005).

### 2.13 Performance considerations

Follows directly from the read/write asymmetry ADR-001 established.

- **Writes** are dominated by predictions (bursty, concentrated near deadlines) and ledger appends
  (concentrated when results finalize). Predictions scale by being an independent aggregate with
  minimal indexes and no shared-row contention. Ledger appends are pure inserts with no update
  contention. The deadline-time prediction burst — the sharpest write spike — is absorbed by the
  stateless horizontally-scalable backend writing to an independent, lightly-indexed prediction
  table.
- **Reads** are dominated by leaderboards. Served from the materialized balance projection plus a
  cached membership-join for group views (§2.7), keeping the hot read path off the transactional
  ledger entirely.
- **Scoring** is a burst of ledger appends and projection updates when a result finalizes; it runs
  asynchronously via the outbox so the result-entry request returns immediately.
- **Reconciliation** (balance = sum of entries) runs on a schedule off the hot path, reading the
  ledger in season-scoped, index-supported chunks.

Closing performance principle: **never let a read compete with an integrity-critical write.** The
ledger is written but rarely read on the hot path; leaderboards are read constantly but never written
by users. This separation is a consequence of the domain model, not an optimization bolted on top.

## 3. Rejected Alternatives

- **Balance stored as authoritative truth** — rejected: recreates the legacy destructive-recalc
  fragility. Balance is a rebuildable projection. *Cost:* reconciliation machinery.
- **Per-group materialized leaderboards** — rejected: combinatorial explosion (a user in ten groups
  predicting five competitions generates fifty leaderboard rows all derived from one balance).
  *Cost:* a read-time membership join.
- **One fixture-result row mutated in place** — rejected: destroys history. Corrections are new
  superseding rows. *Cost:* a superseded flag and a partial unique index.
- **Prediction as part of the Competition aggregate** — rejected: write contention at scale.
  Predictions are independent aggregates. *Cost:* eventual consistency between prediction writes and
  competition-level views.
- **RLS as the primary write boundary** — rejected: RLS cannot enforce business invariants; client
  writes to Tier-1 are denied entirely. *Cost:* a fully-trusted backend that must self-enforce.
- **Partitioning from day one** — rejected as premature infrastructure; we carry partition-ready
  discriminators and defer. *Cost:* a redundant column now.

## 4. Consequences

- The ledger cannot be edited or deleted by any role, including the backend service role — the
  strongest possible anti-tamper posture for the crown-jewel asset.
- Group leaderboards are cheap and unbounded in combination because they are computed, not stored.
- The database enforces the most catastrophic invariants even against an application bug, but the
  service role bypasses RLS, so backend correctness remains mandatory (see ADR-006).
- Large tables can be partitioned later without a domain change, at the cost of a redundant
  discriminator column carried now.
- Migration is reversible phase-by-phase, at the cost of running old and new shapes side by side
  during transition.

## 5. Traceability to Prior ADRs

Aggregate boundaries and the append-only ledger serve Axiom 6 and ADR-002's outbox transaction rule.
The absent competition column on fixtures serves Axiom 3. The absent group column on predictions plus
the *(audience × membership)* read model serve Axioms 4 and 5. Frozen ruleset snapshots and ruleset
versioning serve the frozen-rules invariant. Tier-differentiated RLS serves ADR-002's Tier-1/Tier-3
split. Partition-ready large tables and read/write separation serve ADR-001's "infrastructure scales,
domain doesn't."

## 6. Deferred to Downstream / Implementation

Concrete SQL DDL, exact RLS policy expressions, trigger implementations, the physical
`result_payload` column type, and the migration scripts are implementation artifacts. Event
mechanics are specified in **ADR-005**; the read/write API surface over this schema in **ADR-004**;
security consequences of the service-role bypass in **ADR-006**; environment/promotion of migrations
in **ADR-007**.

---

**Ratification note.** This document is ratified as the Database Architecture layer. Any deviation
requires an amendment recorded here.
