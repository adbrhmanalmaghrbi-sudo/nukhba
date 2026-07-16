# ADR-007 — Deployment Architecture

**Nukhba Platform · Architectural Decision Record**
Status: **Accepted** · Version 1.0 · Date: 2026-07-08
Depends on: ADR-001 Domain · ADR-002 Application · ADR-003 Database · ADR-004 API · ADR-005 Event ·
ADR-006 Security (all Accepted)

> This ADR defines the *operational platform* — topology, environments, promotion, observability,
> tiered operational stance, and the deferred evolution from modular monolith to services. Concrete
> hosting-provider choices, IaC scripts, and dashboards are implementation/operational artifacts
> produced against this decision.

---

## 1. Context

ADR-001 sketched a multi-platform picture; ADR-002 and ADR-003 then committed to a **modular
monolith** with a stateless backend, a Postgres-backed outbox, and Supabase as a managed
Postgres + Auth + Realtime + Storage provider. This ADR reconciles those into an operational whole:
it defines how the system is deployed, promoted, observed, and scaled, so that "millions of users" is
an **infrastructure story that never touches the domain** (ADR-001's load-invariance principle).

The deployment boundary is not merely operational — it is also a security control (ADR-006 §2.7): the
build split between `apps/server` and `apps/mobile` is what keeps the service role and the ledger
write path off client devices.

## 2. Decision

### 2.1 Platform topology

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

The runtime platform is: the **Flutter client** (PWA + mobile), the **stateless Dart backend** behind
a load balancer, the **outbox dispatcher** as a separate worker, and **Supabase** (Postgres, Auth,
Realtime, Storage).

- The backend is **stateless and horizontally scalable** — all state lives in Postgres — so scaling
  to more users is adding backend instances behind the load balancer (ADR-002 §2.14).
- The **outbox dispatcher** runs as a separate worker process, and, when replicated, uses **leader
  election to avoid double-publishing** (at-least-once delivery already assumed by consumers per
  ADR-005 §2.1, but double-publishing is still avoided operationally).
- Clients reach the backend for all Tier-1 operations and reach Supabase directly only for Tier-3
  realtime and reads (ADR-002 §2.2, ADR-004 §2.3).

### 2.2 Environments and promotion

**Three environments: development, staging, production**, each with an **isolated Supabase project and
database** (also a security requirement — ADR-006 §2.7).

- Schema changes flow **forward-only** through the migration pipeline (ADR-003 §2.12) and are
  validated in **staging** — including the phased-migration verification steps — before production.
- Production migrations that carry backfills run with **expand-contract discipline and a rehearsed
  rollback**, matching the Strangler-Fig phases (ADR-003 §2.11). Phase 2 (the ledger) in particular
  must pass its "summed ledger equals pre-migration total" verification in staging before production
  cutover.
- The **build split is enforced at deploy time**: only `apps/server` is built with the service-role
  credential and the full use-case set; `apps/mobile` is built from a dependency graph that
  physically excludes integrity-critical write use-cases (ADR-002 §2.8, §2.14; ADR-006 §2.7).
- Secrets are provisioned per environment and never committed; the service role exists only in the
  backend environment.

### 2.3 Observability

Observability is organized around the **integrity asset**. Three signal classes matter most:

1. **Ledger reconciliation status** — any balance drift alarms immediately; this is the
   **highest-priority alert** in the platform (ADR-003 §2.8, ADR-006 §2.4). Drift is a Sev-1
   integrity incident.
2. **Outbox health** — pending-event backlog, failed/dead-lettered events, and dispatcher liveness. A
   stalled dispatcher means points aren't being recorded (ADR-005 §2.8).
3. **Deadline-burst performance** — prediction write latency around round deadlines, the sharpest
   load spike (ADR-003 §2.13).

Standard signals sit beneath these: request latency, **error rates by the typed error classes from
ADR-004 §2.5**, and auth failures (ADR-006). Every integrity event carries a **trace id** so a single
point can be followed end-to-end: result finalization → scoring → ledger entry → leaderboard
projection (ADR-005 §2.2).

### 2.4 Tiered operational stance

The capability tiers (ADR-001 §2) become **operational SLOs**:

- **Tier-1** (identity, membership, competition, prediction, scoring, ledger) targets the strongest
  availability and correctness guarantees; a Tier-1 incident is **critical**.
- **Tier-3** (social, notifications, engagement, analytics) is **explicitly allowed to degrade**:
  chat can be down, notifications delayed, leaderboards briefly stale — without declaring a platform
  outage.

This tiered stance is what lets the team spend reliability budget where integrity lives rather than
uniformly.

### 2.5 Continuous integration and delivery

- **CI enforces the dependency rules** via import-linting (`tooling/import_lint`) — a violating import
  fails the build (ADR-002 §2.8). This is the mechanical guarantee behind "the client never computes
  points," run on every change.
- **CI runs the layered test suite** (domain/scoring unit tests, use-case tests against in-memory
  fakes, integrity-path tests at both application and database levels) before promotion.
- **Migrations run through the pipeline**, validated in staging before production, with the
  verification steps of the relevant Strangler-Fig phase (ADR-003 §2.11) as gating checks.

### 2.6 Evolution to services (deferred, seams ready)

The modular monolith (ADR-002 §2.4) is the starting topology. The extraction path, **activated only
when load or team scale justifies it**:

- Because contexts communicate solely via published interfaces (ADR-002 §2.6) and outbox events
  (ADR-005), a high-load context — leaderboard reads, or the scoring/ledger flow — can be lifted into
  its own deployable with its communication unchanged.
- Partition-ready large tables (ADR-003 §2.6) and read/write separation (ADR-003 §2.7) are the
  data-side seams for the same evolution.

Recorded principle: **we extract a service in response to a measured constraint, never
speculatively** — premature decomposition was already rejected in ADR-002.

## 3. Rejected Alternatives

- **Microservices from day one** — rejected in ADR-002 and remains rejected: domain is
  load-invariant; decomposition buys distributed-systems complexity before load justifies it.
  *Cost:* module discipline via CI import-lint rather than network boundaries.
- **All-Edge-Functions deployment** — rejected in ADR-002 and remains rejected: hosting the integrity
  core and dispatcher on Edge Functions fights their execution model (cold starts, execution limits,
  weak long-running/worker support). *Cost:* operating a separate backend service; Edge Functions
  retained for the narrow Tier-3/webhook role.
- **Multi-region active-active** — deferred as premature; the schema and stateless backend do not
  preclude it, but it is an infrastructure investment tied to a future measured need. *Cost:* a
  single-region availability ceiling until the need is measured.
- **A single shared database across environments** — rejected: dev/staging/prod each get isolated
  Supabase projects for safe migration validation and secret isolation (ADR-006 §2.7). *Cost:*
  managing three projects.

## 4. Consequences

- Scaling is additive: more backend instances behind the load balancer; no domain change required.
- The dispatcher is a distinct operational component with a liveness/leader-election concern, and its
  health is a first-class integrity signal.
- Migrations are safe-by-process: forward-only, staged, verified, and reversible phase-by-phase, at
  the cost of running old and new shapes side by side during transition.
- The client/server build split is a hard deploy-time gate; a misconfigured build that leaked the
  service role or a write use-case into the client is a release blocker, not a warning.
- Reliability budget is concentrated on Tier-1; Tier-3 degradation is an accepted, non-outage
  condition, simplifying on-call priorities.

## 5. Traceability to Prior ADRs

Stateless horizontally-scalable backend and Postgres-as-only-state serve ADR-001's "infrastructure
scales, domain doesn't" and ADR-002 §2.14. The separate outbox dispatcher realizes ADR-005 §2.1.
Environment isolation and the build split serve ADR-006 §2.7. Reconciliation and outbox observability
serve ADR-003 §2.8 and ADR-005 §2.8. Tiered SLOs realize ADR-001 §2 capability tiering. CI
import-lint enforces ADR-002 §2.8. The deferred service-extraction path preserves ADR-002 §2.4's
"modular monolith first, service extraction later."

## 6. Deferred to Downstream / Implementation

Concrete hosting provider(s), load-balancer configuration, IaC (Terraform/etc.), dashboard and
alert-rule definitions, leader-election mechanism, secret-management tooling, and the retention/
archival job schedules are implementation and operational artifacts produced against this ADR.
Incident-response runbooks (notably reconciliation-drift Sev-1 and outbox-stall) are operational
documents traceable to §2.3 and ADR-006.

---

**Ratification note.** This document is ratified as the Deployment Architecture layer. Any deviation
requires an amendment recorded here.
