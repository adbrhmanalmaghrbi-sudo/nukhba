# ADR-002 — Application Architecture

**Nukhba Platform · Architectural Decision Record**
Status: **Accepted** · Version 1.0 · Date: 2026-07-08
Depends on: ADR-001 Domain Architecture (Accepted)
Governs: ADR-003 Database, ADR-004 API, ADR-005 Event, ADR-006 Security, ADR-007 Deployment

---

## 1. Context

ADR-001 fixed *what the system is*: nine bounded contexts, three capability tiers, and six
axioms whose non-negotiable core is Axiom 6 — the integrity of the competitive record. This ADR
fixes *how the code is organized to protect that record*. Every structural decision below traces
to a domain axiom or invariant; every technology choice records its rejected alternative and its
accepted cost.

The decision is forced by a real tension in the chosen stack. The client is Flutter/Dart, and the
managed backend is Supabase (Postgres + Auth + Realtime + Edge Functions + Storage). Supabase's
default posture invites the client to talk *directly* to the database over auto-generated
REST/Realtime APIs. ADR-001 Axiom 6 forbids exactly that for anything integrity-critical. The
central architectural act of this document is therefore a single hard line, from which most of the
rest is deduced:

> **Integrity-critical writes go through a server-authoritative application layer. Only
> non-critical reads and Tier-3 realtime may touch Supabase directly.**

## 2. Decision

### 2.1 Overall system architecture — layered and event-driven

Four macro-layers, with dependencies pointing **inward and downward only**.

```
┌──────────────────────────────────────────────────────────────┐
│  CLIENT (Flutter)                                             │
│  Presentation · State · Client-side read models only         │
│  Talks to server via typed API client. Never computes points.│
└───────────────────────────────┬──────────────────────────────┘
                                │ HTTPS (typed contracts)
┌───────────────────────────────▼──────────────────────────────┐
│  APPLICATION / EDGE LAYER (Backend)                          │
│  Auth verification · Use-case orchestration · Business rules │
│  The ONLY place integrity-critical writes are authorized.    │
└───────────────────────────────┬──────────────────────────────┘
                                │ in-process context calls + Event Bus
┌───────────────────────────────▼──────────────────────────────┐
│  DOMAIN LAYER (pure, framework-free)                         │
│  Entities · Invariants · Game Engine · Scoring · policies    │
│  No knowledge of Supabase, HTTP, Flutter, or Postgres.       │
└───────────────────────────────┬──────────────────────────────┘
                                │ repository interfaces (ports)
┌───────────────────────────────▼──────────────────────────────┐
│  INFRASTRUCTURE / DATA LAYER                                 │
│  Postgres (truth) · Outbox · Read projections · Cache        │
│  Supabase Auth · Realtime (Tier-3 only) · ACL to feeds       │
└──────────────────────────────────────────────────────────────┘
```

The Domain layer at the center depends on nothing. Infrastructure and Application depend on Domain,
never the reverse. This is the enforcement mechanism for "integrity is core": the sacred rules
physically cannot import a database driver or an HTTP framework.

### 2.2 Client and server responsibilities

The split is governed by one test carried from ADR-001: **does it touch the competitive record?**
If yes, it is the server's exclusive responsibility.

**The client (Flutter) is responsible for** rendering, local UI state, input capture, optimistic
display, caching read models for offline resilience, and subscribing to Tier-3 realtime (chat, live
standings hints). The client *may* hold a read-only mirror of domain shapes to render intelligently
— it knows what a prediction looks like — but it treats all of that as display data, never as the
source of truth.

**The server is responsible, exclusively, for** verifying identity, enforcing every invariant
(deadline immutability, ruleset freezing, membership-based authorization), running the Game Engine
and the Scoring function, appending PointEntries, and computing/persisting projections. **No point
is ever computed on the client.** This is the direct reversal of the legacy client-side calculation
path, and it is the entire reason the Application layer exists.

Anti-drift rule: the client never constructs a Supabase REST write to any Tier-1 table. Those tables
are protected by RLS that denies client writes outright; the only writer is the backend using a
privileged service-role connection. The client's write vocabulary is exactly the server's use-case
API (ADR-004).

### 2.3 Monorepo structure

A single monorepo holds client, server, and the contracts that bind them — because client and server
must agree exactly on the shape of a prediction, a result, and an API request. A shared contract
package makes that agreement compile-checked rather than hoped-for.

Because the client is Dart/Flutter, the backend is a **Dart backend** (server framework such as Dart
Frog or Serverpod). Domain entities, the Game Engine interface, and the Scoring function are written
*once* in Dart and shared between client read-models and server authority, with contracts guaranteed
identical.

```
nukhba/
├── apps/
│   ├── mobile/                 # Flutter client
│   └── server/                 # Dart backend (use-cases, HTTP, event bus)
├── packages/
│   ├── domain/                 # PURE domain: entities, invariants,
│   │                           #   game engine iface, scoring function
│   ├── contracts/              # API DTOs, request/response, event schemas
│   ├── application/            # use-cases, ports (repository interfaces)
│   ├── infrastructure/         # repo impls, Supabase adapters, ACL
│   ├── game_engines/           # concrete engine implementations
│   └── shared/                 # cross-cutting: result types, ids, errors
├── supabase/
│   ├── migrations/             # SQL schema (ADR-003)
│   └── functions/              # Edge Functions (Tier-3 / webhooks only)
└── tooling/                    # scripts, codegen, CI, import-lint
```

The `domain` and `application` packages are shared between `apps/server` (which executes them with
authority) and `apps/mobile` (which imports only the read-safe subset). Dependency rules (§2.8)
prevent the client from importing anything that would let it write authoritatively.

### 2.4 Package / module boundaries — modular monolith

Each bounded context from ADR-001 maps to a module *within* the layered packages, not to a separate
microservice. **Modular monolith first, service extraction later.**

```
packages/domain/lib/
├── identity/
├── community/
├── football_data/
├── competition/
├── scoring/
├── ledger/
├── engagement/       # projection contracts only
└── shared_kernel/    # ids, value objects shared across contexts

packages/application/lib/
├── identity/         (use-cases + repository ports)
├── community/
├── football_data/
├── competition/
├── scoring/
├── ledger/
└── ...
```

Contexts communicate only through published interfaces and events (§2.6, ADR-005), so later
extraction into services is mechanical: the seams already exist.

### 2.5 Clean Architecture layers

Four concentric layers; source-code dependencies point **only inward**.

```
        ┌─────────────────────────────────────┐
        │  Frameworks & Drivers (outermost)   │
        │  Flutter widgets, Dart Frog handlers,│
        │  Supabase client, Postgres driver   │
        │   ┌─────────────────────────────┐   │
        │   │  Interface Adapters         │   │
        │   │  Controllers, Presenters,   │   │
        │   │  Repository implementations,│   │
        │   │  ACL mappers                │   │
        │   │   ┌─────────────────────┐   │   │
        │   │   │  Application (use-  │   │   │
        │   │   │  cases) + Ports     │   │   │
        │   │   │   ┌─────────────┐   │   │   │
        │   │   │   │  Domain     │   │   │   │
        │   │   │   │ (entities,  │   │   │   │
        │   │   │   │ invariants) │   │   │   │
        │   │   │   └─────────────┘   │   │   │
        │   │   └─────────────────────┘   │   │
        │   └─────────────────────────────┘   │
        └─────────────────────────────────────┘
```

- **Domain (innermost):** entities, value objects, invariants, the Game Engine interface, the pure
  Scoring function. Zero framework imports. "A prediction is immutable after deadline" and
  "balance = sum of entries" live here as code, testable with no database.
- **Application:** use-cases (`SubmitPrediction`, `FinalizeResult`, `ScoreRound`) that orchestrate
  domain objects and declare **ports** — repository/service interfaces the domain needs but does
  not implement.
- **Interface Adapters:** repository *implementations*, HTTP controllers, the ACL mapping external
  feed data into Football Data entities, presenters shaping DTOs.
- **Frameworks & Drivers:** Flutter, the HTTP server framework, the Supabase SDK, the Postgres
  driver — replaceable details.

Payoff: the Scoring function and every invariant are unit-testable with in-memory fakes, no Supabase
required — which is what makes "deterministic, replayable scoring" enforceable rather than
aspirational.

### 2.6 Communication between bounded contexts

Two modes, chosen by whether the interaction is a *query* or a *reaction*.

- **Synchronous, in-process, via published interfaces** — for queries and command orchestration
  within a single use-case. When Competition needs a fixture's result to score a round, it calls
  Football Data's published query port. Calls flow through interfaces defined in the *calling*
  context, so no context depends on another's internals — only on its contract.
- **Asynchronous, via the Event Bus** — for reactions across contexts. When a result is finalized,
  downstream contexts (Ledger, Engagement, Notification) react to an event rather than being called
  directly. This preserves ADR-001's rule that integrity-critical writes are never chained
  synchronously in a way that leaves inconsistent state on partial failure.

Hard rule: **no context imports another context's entities or repositories directly.** Cross-context
needs are met through a published query interface or through events carrying self-contained data.
This is what makes future service extraction mechanical. (Full event mechanics: ADR-005.)

### 2.7 Event-driven architecture (summary; detailed in ADR-005)

The event backbone realizes the ADR-001 canonical flow: result finalized → scored → recorded →
projected. Correctness is guaranteed by the **transactional outbox pattern**: within a single
database transaction, a use-case writes both its domain change *and* an event row to an `outbox`
table; a separate dispatcher reads the outbox and publishes to consumers. An event is emitted **if
and only if** the write committed — no lost events, no phantom events. Consumers are idempotent,
keyed by event id, because delivery is at-least-once. ADR-005 specifies the event catalogue,
payloads, dispatcher, and consumer contracts.

### 2.8 Dependency rules

Enforced by CI import-linting (`tooling/import_lint`), not goodwill.

- Domain depends on nothing outside `shared_kernel`.
- Application depends on Domain only.
- Infrastructure depends on Application and Domain (to implement their ports); nothing depends on
  Infrastructure except the composition root.
- Contracts depend on nothing (pure DTOs).
- No context module imports another context module's internals.
- The Flutter client may import `domain`/`contracts` **read-only surfaces** and `application`
  **query ports**, but is forbidden from importing repository implementations or any use-case that
  performs an integrity-critical write.

The last rule is the technical guarantee behind "the client never computes points": the code that
computes points lives in `domain/scoring` and is invoked only by server-side use-cases. The client
*can* read scoring rules to *explain* points, but the authoritative computation path is not
reachable from client code because the persisting use-case is compiled only into `apps/server`.

### 2.9 Repository pattern

Every persistence need is a **port** (interface) in Application and an **adapter** (implementation)
in Infrastructure. Domain and use-cases speak only to ports.

```
application/ledger/ports/point_entry_repository.dart   (interface)
   append(PointEntry)            // append-only; no update/delete methods exist
   entriesFor(participant, season)
   balanceFor(participant, season)

infrastructure/ledger/postgres_point_entry_repository.dart  (impl)
   ...implements the above against Postgres
```

Two invariant-reinforcing choices: (1) the `PointEntryRepository` interface **exposes no update or
delete method** — the append-only invariant cannot be violated because the vocabulary to violate it
does not exist; (2) repositories accept/return domain entities, never raw rows — mapping happens in
the adapter, so the schema can evolve without touching the domain.

Read-heavy projections (leaderboards) use **separate read-optimized query objects**, distinct from
write repositories — a light CQRS split. Writes go through Tier-1 repositories with full rigor;
leaderboard reads go through query objects that may hit Supabase read paths or cached projections
directly.

### 2.10 Game Engine implementation strategy

The Game Engine is ADR-001's Tier-2 seam — interface, not runtime.

```
domain/competition/game_engine/game_engine.dart  (interface)
   PredictionShape  describePredictionShape()      // what a prediction looks like
   ValidationResult validatePrediction(input, roundContext)
   LifecycleState   advanceLifecycle(current, event)
   // scoring is delegated to the Scoring context, not embedded here

game_engines/football_scoreline/                  (the ONE impl today)
   FootballScorelineEngine implements GameEngine
```

Each game type is a class implementing `GameEngine`, registered in a **registry** keyed by
`format_type`. Competition resolves the engine for a round from its stored `format_type` and
delegates prediction-shape and lifecycle questions to it. Adding Survivor/Bracket/Fantasy later
means writing a new class and registering it — Core is untouched.

Boundary made explicit: the Game Engine defines *the shape and lifecycle of a prediction*; the
Scoring context defines *how a prediction earns points*. Keeping them separate lets a future game
type reuse scoring primitives, and lets a ruleset change without touching the engine.

### 2.11 ACL implementation

The Anti-Corruption Layer sits at the edge of Football Data, translating any external feed into
canonical domain entities so no provider's model contaminates the domain.

```
infrastructure/football_data/acl/
├── provider_client/            # raw feed clients (API-Football, etc.)
├── dto/                        # provider-shaped DTOs (never leave ACL)
├── identity_resolution/        # external IDs → canonical Team/Fixture IDs
└── mappers/                    # provider DTO → domain entity
```

Two responsibilities: (1) **shape translation** — provider fixture/result JSON → `Fixture` /
`FixtureResult`, producing `result_payload` behind the interface (preserving the multi-sport seam);
(2) **identity resolution** — providers disagree on identity, so the ACL maintains a mapping
(external_source + external_id → canonical_id) and is the sole place reconciliation happens. Manual
admin entry is modeled as *just another provider* behind the same interface, so switching from
manual to automated ingestion changes only which adapter is wired in.

### 2.12 Technology mapping

```
Concern                     Technology            Notes
─────────────────────────── ───────────────────── ──────────────────────────
Client                      Flutter (Dart)        PWA + mobile from one base
Client state                Riverpod (or Bloc)    read-models only; no scoring
Shared domain/contracts     Dart packages         single source of truth
Backend runtime             Dart (Dart Frog /     shares domain code with client
                            Serverpod)
Auth                        Supabase Auth         verified server-side (JWT)
Primary DB (truth)          Supabase Postgres     Tier-1 tables, RLS deny-client-write
Event store / outbox        Postgres tables       transactional outbox
Realtime (Tier-3 only)      Supabase Realtime     chat, live standings hints
Serverless glue / webhooks  Supabase Edge Fns     Tier-3 + provider webhooks only
Read projections            Postgres (+ cache)    leaderboards, materialized views
Cache                       (in-memory / managed) leaderboard reads
File/media (avatars, memes) Supabase Storage      Tier-3
```

Pivotal mapping: **Supabase is a managed Postgres + Auth + Realtime + Storage provider, not a
client-facing backend.** RLS on Tier-1 tables denies all client writes; the backend connects with a
privileged service role and is the sole authoritative writer. RLS remains defense-in-depth for reads
and for Tier-3 tables.

### 2.13 Consolidated folder structure

```
nukhba/
├── apps/
│   ├── mobile/
│   │   └── lib/
│   │       ├── features/          # UI per feature (predictions, groups, chat)
│   │       ├── state/             # Riverpod providers (read-models)
│   │       ├── api_client/        # typed client over contracts
│   │       └── main.dart
│   └── server/
│       └── lib/
│           ├── routes/            # HTTP handlers (controllers)
│           ├── composition/       # DI wiring (composition root)
│           ├── outbox_dispatcher/ # event publishing
│           └── main.dart
├── packages/
│   ├── domain/lib/<context>/
│   ├── application/lib/<context>/
│   ├── infrastructure/lib/<context>/
│   ├── contracts/lib/
│   ├── game_engines/lib/
│   └── shared/lib/
├── supabase/
│   ├── migrations/
│   └── functions/
└── tooling/
    ├── import_lint/
    └── ci/
```

### 2.14 Deployment stance (summary; detailed in ADR-007)

```
┌───────────────┐        ┌──────────────────────────────────┐
│  Flutter PWA  │        │  Supabase (managed)              │
│  + mobile     │◄──────►│  Auth · Realtime · Storage       │
└──────┬────────┘        │  Postgres (truth + outbox +      │
       │                 │  projections)                    │
       │ HTTPS           └───────────────▲──────────────────┘
       ▼                                 │ privileged (service role)
┌───────────────────────────────┐        │
│  Nukhba Backend (Dart)        │────────┘
│  - HTTP API (use-cases)       │
│  - Outbox dispatcher (worker) │◄──── provider webhooks / manual entry (ACL)
│  Stateless; horizontally      │
│  scalable behind a load       │
│  balancer                     │
└───────────────────────────────┘
```

The backend is **stateless and horizontally scalable** — all state lives in Postgres. The **outbox
dispatcher** runs as a separate worker (or leader-elected instance) so event publishing is decoupled
from request handling. Deployment discipline doubles as a security control: only `apps/server` is
built with the service-role credential and the full use-case set; `apps/mobile` is built from a
dependency graph that physically excludes integrity-critical write use-cases. ADR-007 specifies
environments, promotion, and scaling.

## 3. Rejected Alternatives

- **TypeScript/Node backend with a separately-maintained contract layer** — rejected: duplicates
  the domain vocabulary in two languages and re-introduces client/server divergence. *Accepted
  cost:* the Dart server ecosystem is smaller than Node's; some Supabase tooling assumes JS.
- **Microservices from day one** — rejected: domain architecture is load-invariant (ADR-001);
  premature decomposition buys distributed-systems complexity before load justifies it. *Accepted
  cost:* module discipline maintained by convention + CI import-lint, not network boundaries.
- **Postgres outbox vs. a message broker (Kafka/RabbitMQ)** — broker rejected as over-infrastructure
  for current scale. *Accepted cost:* throughput bounded by Postgres and polling latency; publish
  target is swappable later without touching use-cases.
- **Backend-authoritative vs. Supabase-direct (client → PostgREST) with RLS as the only boundary**
  — Supabase-direct rejected: RLS answers "may this user touch this row?" but not "may this user
  submit after the deadline?" or "were the rules applied honestly?" — business invariants requiring
  the Application layer (Axiom 6). *Accepted cost:* a backend to build, deploy, and operate.
- **Separate backend vs. all-Edge-Functions** — all-Edge rejected: hosting the integrity core and
  dispatcher there fights their execution model (cold starts, execution limits, weak long-running
  support). *Accepted cost:* operate a separate backend; Edge Functions kept for Tier-3/webhooks.
- **Configurable single engine with feature flags vs. engine-per-class** — configurable engine
  rejected: game lifecycles are irreconcilable (Bracket is a dependency tree; Survivor has
  elimination); flags would tangle within a year. *Accepted cost:* boilerplate per engine.

## 4. Consequences

- The client can never author an integrity-critical write; the write path is physically absent from
  its build (§2.8, §2.14).
- The domain and scoring logic are unit-testable without infrastructure, making the ADR-001
  invariants enforceable.
- Service extraction later is mechanical because contexts already communicate only via published
  interfaces and events.
- The team must operate and secure a real backend and its service-role credential (see ADR-006).
- Cross-context laziness (a direct import) is *physically possible* in a monolith and must be caught
  by CI import-lint (`tooling/import_lint`), not by review memory.

## 5. Traceability to ADR-001 Axioms

Backend-authoritative writes and the inward dependency rule serve Axiom 6 (integrity is core). Shared
Dart domain serves the predict-once correctness of Axiom 4. The Game Engine registry and the ACL
serve Axiom 3's seams. Separate leaderboard query objects serve Axiom 5's *(audience × competition)*
reads. The append-only repository interface serves the Ledger invariant. The transactional outbox
serves the "no half-scored round" guarantee.

## 6. Deferred to Downstream ADRs

- Concrete schema of the transactional outbox and projection tables → **ADR-003**.
- Physical `result_payload` representation behind the FixtureResult interface → **ADR-003**.
- Event catalogue, payload shapes, dispatcher and consumer contracts → **ADR-005**.
- Environments, promotion pipeline, scaling and rollback discipline → **ADR-007**.
- The typed use-case API surface between Flutter and backend → **ADR-004**.

---

**Ratification note.** This document is ratified as the Application Architecture layer. Any deviation
requires an amendment recorded here. Subsequent ADRs must conform to it.
