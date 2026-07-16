# ADR-004 — API Architecture

**Nukhba Platform · Architectural Decision Record**
Status: **Accepted** · Version 1.0 · Date: 2026-07-08
Depends on: ADR-001 Domain · ADR-002 Application · ADR-003 Database (all Accepted)
Related: ADR-005 Event · ADR-006 Security

> This ADR defines the *contract surface* between the Flutter client and the backend. It is not an
> exhaustive endpoint reference; it is the architecture that governs every endpoint. Concrete DTO
> field lists and route paths are implementation artifacts produced in `packages/contracts` against
> this decision.

---

## 1. Context

ADR-002 reversed the legacy Supabase-direct model: integrity-critical writes go only through the
server-authoritative Application layer. The API is the visible face of that reversal. It must be a
**use-case API**, not a list of database tables exposed over HTTP — because table-CRUD-over-HTTP is
exactly the boundary ADR-002 rejected.

Each endpoint corresponds to a business action the server is authoritative over, and **the client's
entire write vocabulary is exactly this surface**. The contracts live in the shared
`packages/contracts` Dart package (ADR-002 §2.3), so client and server are compile-checked against
identical shapes — eliminating the client/server divergence risk that a hand-maintained,
two-language contract would reintroduce.

## 2. Decision

### 2.1 API design principles

The API is **command/query separated**, mirroring the database's CQRS-lite split (ADR-003 §2.7).
Commands are integrity-critical actions routed exclusively through the backend; queries are reads —
Tier-1 reads go through the backend or RLS-governed read paths, and the client may satisfy some
Tier-3 reads directly from Supabase.

Four rules govern every endpoint:

1. **The API speaks in domain intents, not table operations** — `SubmitPrediction`, not
   `INSERT into predictions`.
2. **Every command is authorized server-side against business invariants**, not just row permissions
   — the deadline check, the membership check, the frozen-ruleset check happen here before any write
   (see ADR-006 §2.3 two-layered authorization).
3. **Every command is idempotent or safely retryable** — clients retry on network failure, so
   commands carry a client-generated idempotency key where a duplicate would otherwise double-write.
4. **Responses never leak internal representation** — DTOs are shaped for the client, decoupled from
   schema (ADR-003: schema can evolve without breaking the domain, and here, without breaking the
   client).

### 2.2 Command surface (Tier-1, backend-exclusive)

Commands are grouped by bounded context; each is an authoritative use-case (ADR-002 §2.5).

- **Identity commands** — registration, login/session issuance (credential verification delegated to
  Supabase Auth, but the *domain* session is issued here), profile update, device registration for
  notifications. Return session tokens and profile DTOs, never raw credentials.
- **Community commands** — create a group, invite a user, accept/decline an invitation, change a
  member's role, leave a group. Each authorizes against the caller's role in that group — only an
  owner/admin may invite or change roles. Tier-1 because they mutate the membership set that drives
  all audience filtering.
- **Competition commands** — join a competition season (creating a Participant), and — admin-scoped
  — create competitions/seasons/rounds, add fixtures to a round, and **lock a round** (which triggers
  the ruleset snapshot). Locking is a distinct, deliberate command because it is the moment the
  frozen-rules invariant takes effect.
- **Prediction commands** — the highest-volume surface: submit or update a prediction for a
  round-fixture, and set a modifier. The server validates against the round deadline (rejecting
  post-deadline writes per the invariant) and against the Game Engine's `validatePrediction` for the
  round's format. **Carries an idempotency key** because deadline-time retries are common.
- **Football Data / Admin commands** — finalize a fixture result and issue a correction. Finalizing
  emits `FixtureResultFinalized` through the outbox (ADR-003 §2.9, ADR-005); a correction inserts a
  superseding result. Admin/service-role scoped.
- **Ledger commands** — deliberately minimal and admin-only: manual adjustment and bonus, each
  producing an append-only entry. **There is no "recalculate" command and no "set balance" command**
  — those verbs do not exist in the API, mirroring their absence in the repository (ADR-002 §2.9) and
  the database (ADR-003 §2.4, §2.8).

### 2.3 Query surface

- **Tier-1 queries** (backend or RLS-governed reads): a user's own predictions for a round; a round's
  fixtures and deadline; a participant's own ledger history; competition/season/round metadata.
  The **leaderboard query** is the marquee read and takes the *(audience × competition)* shape from
  ADR-003: parameters are a competition/season plus an *optional* group id (absent = global
  audience). The backend resolves the audience via the membership set and returns a ranked, paginated
  page from the balance projection.
- **Tier-3 queries** the client may satisfy directly via Supabase under RLS: chat history, reactions,
  notification preferences, and realtime subscriptions for live-standings hints and new messages.

### 2.4 Contract shapes and versioning

Every request/response is a versioned DTO in `packages/contracts`. Payloads that vary by game type —
notably a prediction's shape — are represented behind the Game Engine's `PredictionShape` abstraction
rather than hard-coded scoreline fields, preserving the multi-sport and multi-game-type seams
(ADR-001 exclusions; ADR-002 §2.10).

The API is **versioned by URL prefix**; DTOs additionally carry a schema version so archived-event
replay and gradual client rollout don't break (ADR-003 §2.12, ADR-005). Backward-incompatible
changes follow **expand-contract**: add the new field/endpoint, migrate clients, retire the old.

### 2.5 Error contract

Errors are a **closed, typed set** distinguishing four classes:

1. **Authorization failures** — identity/role not permitted the action.
2. **Invariant violations** — deadline passed, not a member, round locked, frozen ruleset.
3. **Validation failures** — malformed prediction for the format.
4. **Transient/infrastructure failures** — safe to retry.

The client treats **invariant violations as terminal** (do not retry) and **transient failures as
retryable**. The distinction must be explicit in the contract so clients behave correctly under the
idempotency model. This same four-class taxonomy is preserved end-to-end through the layers
(Coding-standards rule; see ADR-002 §2.6 error boundaries).

### 2.6 Idempotency model

Commands where a duplicate would double-write (chiefly `SubmitPrediction`, ledger adjustments, result
finalization) carry a **client-generated idempotency key**. The backend records processed keys per
command and returns the original result on a duplicate rather than re-executing. This makes
client-side retry-on-network-failure safe and is the API-side counterpart to the at-least-once,
idempotent-consumer model of the event backbone (ADR-005). Queries are naturally idempotent and carry
no key.

## 3. Rejected Alternatives

- **Exposing PostgREST / auto-generated CRUD to the client** — rejected: it is exactly the
  current-system boundary ADR-002 reversed. *Cost:* hand-authoring a use-case API.
- **GraphQL** — rejected as premature flexibility that weakens the "commands are explicit
  authoritative intents" model and complicates per-field invariant enforcement. *Cost:* less
  client-side query flexibility, which the read model's fixed shapes don't need.
- **Untyped JSON contracts** — rejected: reintroduces the client/server divergence the shared Dart
  package eliminates. *Cost:* none material; the shared package is already required by ADR-002.

## 4. Consequences

- The client's write capability is bounded exactly by the command surface; there is no path to write
  a Tier-1 table outside a use-case.
- Contracts are compile-checked across client and server, so a shape change cannot silently diverge.
- Every high-volume or double-write-risk command must implement the idempotency-key handshake, adding
  a small per-command obligation.
- API evolution is constrained to expand-contract; no breaking change ships without a migration
  window, which the URL-prefix + DTO schema-version scheme supports.
- Because the leaderboard query is *(audience × competition)*, the backend — not the client — owns
  audience resolution, keeping Axiom 5 correct regardless of client behavior.

## 5. Traceability to Prior ADRs

Use-case (not table) endpoints and backend-exclusive commands serve Axiom 6 and ADR-002's reversal.
The `PredictionShape`-abstracted prediction payload serves Axiom 3 and ADR-002 §2.10's Game Engine
seam. The *(audience × competition)* leaderboard query serves Axioms 4 and 5 and ADR-003 §2.7. The
absence of "recalculate"/"set balance" commands serves the append-only ledger invariant (ADR-003
§2.8). The idempotency-key model complements ADR-005's at-least-once delivery. The typed error
contract feeds ADR-006's two-layered authorization and the client's correct retry behavior.

## 6. Deferred to Downstream / Implementation

Concrete DTO field lists, exact route paths and URL-version prefixes, pagination parameters, and the
per-command idempotency-key storage schema are implementation artifacts in `packages/contracts` and
`apps/server`. Event payload schemas referenced by result/ledger commands are specified in **ADR-005**.
Rate limiting and auth-token verification specifics are specified in **ADR-006**.

---

**Ratification note.** This document is ratified as the API Architecture layer. Any deviation
requires an amendment recorded here.
