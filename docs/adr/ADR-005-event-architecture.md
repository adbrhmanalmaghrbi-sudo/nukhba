# ADR-005 — Event Architecture

**Nukhba Platform · Architectural Decision Record**
Status: **Accepted** · Version 1.0 · Date: 2026-07-08
Depends on: ADR-001 Domain · ADR-002 Application · ADR-003 Database (all Accepted)
Related: ADR-004 API · ADR-006 Security · ADR-007 Deployment

> This ADR specifies the event backbone in full: delivery guarantees, the outbox mechanism, the event
> catalogue, payload discipline, consumer contracts, ordering, retries, and replay. Concrete
> serialization formats and consumer table DDL are implementation artifacts produced against this
> decision.

---

## 1. Context

ADR-001 established the canonical cross-context flow — **result finalized → scored → recorded →
projected** — and the rule that integrity-critical writes are never chained synchronously across
contexts in a way that leaves inconsistent state on partial failure. ADR-002 chose asynchronous,
event-driven communication for cross-context *reactions* (synchronous published interfaces are used
only for in-process queries within a single use-case). ADR-003 defined the physical `outbox_event`
table.

This ADR fixes the event architecture as a first-class concern rather than a side note, because the
correctness of the competitive record depends on it: a half-scored round, a lost `PointsAwarded`
event, or a double-applied ledger entry are all Axiom-6 violations.

## 2. Decision

### 2.1 The core guarantee — transactional outbox, exactly-once *effect*

The critical correctness concern is that "score a round" must not half-succeed. We adopt the
**transactional outbox pattern**:

```
Use-case (single DB transaction):
  ├─ write domain change (e.g. FixtureResult)
  └─ write OutboxEvent(<EventType>)
        ▼ committed atomically
Dispatcher polls outbox → publishes event → marks published
        ▼
Consumers react (idempotently, keyed by event id)
```

Within one database transaction a use-case writes both its domain change *and* an event row to the
`outbox_event` table. A separate dispatcher reads the outbox and publishes to consumers. An event is
emitted **if and only if** the write committed — no lost events, no phantom events.

Delivery from the outbox is **at-least-once**. We therefore achieve *exactly-once effect* not by
exactly-once delivery (impossible in general) but by **idempotent consumers keyed by event id**. A
consumer that isn't idempotent is a defect, because it will eventually double-apply on a redelivery.

### 2.2 The canonical scoring flow

```
FinalizeResult use-case (single DB transaction):
  ├─ write FixtureResult
  └─ write OutboxEvent(FixtureResultFinalized)
        ▼ committed atomically
Dispatcher publishes FixtureResultFinalized
        ▼
Competition consumer → invokes ScoreRound use-case
        ├─ (single transaction) append PointEntry rows
        └─ write OutboxEvent(PointsAwarded)
              ▼ committed atomically
      ┌─────────────────┬──────────────────────┐
      ▼                 ▼                      ▼
   Ledger*          Engagement            Notification
 (already          (rebuild               (notify the
  appended)         projections)           participant)
```

\*The ledger append happens inside `ScoreRound`'s transaction alongside the `PointsAwarded` outbox
row; Engagement and Notification are downstream consumers that update projections / send messages and
can fail and retry without corrupting the ledger. This realizes ADR-001's flow: Ledger is the source
of truth; Engagement and Notification are rebuildable/retryable downstream.

### 2.3 Event categories

Events fall into three categories with different reliability postures:

- **Integrity events** — `FixtureResultFinalized`, `PointsAwarded`, `PointsAdjusted`. Flow through
  the outbox and drive Tier-1 consumers. These are the events the whole pattern exists to protect.
- **Notification / engagement events** — drive Tier-3 consumers that may fail and retry without
  corrupting truth (e.g. update a streak, send a push). Also delivered via the outbox for
  reliability, but their failure is not an integrity incident.
- **Realtime UI events** — new chat message, live-standings-changed hints — delivered to clients via
  **Supabase Realtime**, *not* the outbox. Even here the client treats them as display hints and
  trusts server reads for anything that counts (ADR-002 §2.2).

### 2.4 Event catalogue (initial)

Named events are stable contracts; adding an event is additive, changing one follows §2.8 versioning.

| Event | Emitted by (use-case) | Primary consumers | Category |
|---|---|---|---|
| `FixtureResultFinalized` | FinalizeResult (Football Data) | Competition (ScoreRound) | Integrity |
| `PointsAwarded` | ScoreRound (Competition/Scoring→Ledger) | Engagement, Notification | Integrity |
| `PointsAdjusted` | AdjustLedger / IssueCorrection (Ledger, admin) | Engagement, Notification | Integrity |
| `RoundLocked` | LockRound (Competition) | Notification (deadline reminders), Engagement | Notification/Engagement |
| `MembershipChanged` | Community commands (join/leave/role) | Engagement (audience-affecting projections) | Notification/Engagement |
| `ParticipantJoined` | JoinCompetition (Competition) | Engagement, Notification | Notification/Engagement |

The catalogue is expected to grow; each new event names its emitter, consumers, and category before
it ships.

### 2.5 Payload discipline

Every outbox event payload is **self-contained**: it carries the data a consumer needs so consumers
**never back-reference into another context's tables** (ADR-002 §2.6, ADR-003 §2.9). This is what
keeps consumers decoupled and future service-extraction mechanical. The `outbox_event` row also
carries an `aggregate_ref` for traceability and an event id used as the idempotency key.

A payload is a *snapshot of the fact at emission time*, not a live pointer. If `PointsAwarded`
carries the amount and participant/season, the Engagement consumer updates its projection without
querying the Ledger; if it needs the full history it rebuilds from the ledger explicitly (§2.9).

### 2.6 Ordering

Global total ordering is neither guaranteed nor required. What is required is **per-aggregate
causal ordering where it matters**:

- The outbox dispatcher polls `(status = pending)` ordered by `created_at` (ADR-003 §2.5 index),
  giving approximate emission order.
- Ledger entries carry an **entry sequence/position per `(participant, season)`** (ADR-003 §2.8),
  giving deterministic per-participant ordering independent of event delivery order.
- Consumers that require ordering (e.g. incremental balance projection) key off the ledger position,
  not off delivery order, so out-of-order or duplicated delivery cannot corrupt the projection.

### 2.7 Consumer contracts

Every consumer must:

1. **Be idempotent**, keyed by event id, with a **processed-event checkpoint** table so duplicates
   are discarded (ADR-003 §2.9).
2. **Be rebuildable** where it maintains a projection — a corrupted or schema-changed projection can
   be dropped and rebuilt from the event stream / ledger without touching truth (§2.9).
3. **Fail safely** — a Tier-3 consumer failure is retried and, on exhausting retries, dead-lettered
   (§2.8); it never blocks or corrupts the integrity path.
4. **Never emit an integrity event by direct publish** — only through the transactional outbox
   (Coding-standards rule; ADR-002 §2.7).

### 2.8 Retries, dead-lettering, and schema versioning

- **Retries.** The `outbox_event` row carries a `status` (pending / published / failed) and a
  retry/attempt counter (ADR-003 §2.9). The dispatcher retries `failed`/unacknowledged events with
  backoff.
- **Dead-lettering.** Events exceeding the retry ceiling move to a dead-letter disposition for manual
  inspection; for integrity events this is an operational alert (ADR-007 §2.3 outbox health).
- **Schema versioning.** Each `event_type` carries a **schema version** in its payload (ADR-003
  §2.12). Consumers tolerate known versions; backward-incompatible payload changes follow
  expand-contract — add the new field/version, migrate consumers, retire the old. This lets archived
  events replay against evolved consumers.

### 2.9 Retention and replay

Published events are **retained for a window** (audit, replay, new-consumer bootstrap), then archived
to cold storage (ADR-003 §2.6 outbox archival). The outbox is therefore both the reliable delivery
mechanism and a **secondary audit log** of everything integrity-relevant that happened.

Two replay uses are first-class:

- **Projection rebuild** — drop a corrupted/changed projection and rebuild it from the ledger and/or
  retained events; because payloads are self-contained and versioned, replay is deterministic.
- **New-consumer bootstrap** — a newly added Tier-3 consumer can be brought current by replaying the
  retained window rather than requiring a bespoke backfill.

The Ledger itself is the strongest replay source for points: its entries *are* events and its balance
is their fold (ADR-003 §2.8), so points can always be reconstructed even if the outbox window has
rolled over.

## 3. Rejected Alternatives

- **A dedicated message broker (Kafka / RabbitMQ) from day one** — rejected as over-infrastructure
  for current scale; a Postgres-backed outbox + lightweight dispatcher covers the modular monolith's
  needs with far less operational burden. *Accepted cost:* throughput is bounded by Postgres and
  polling latency; the dispatcher's publish target is swappable to a real broker later without
  touching use-cases.
- **Direct synchronous cross-context calls for reactions** (e.g. FinalizeResult calls Ledger inline)
  — rejected: chains integrity-critical writes across contexts so a partial failure leaves
  inconsistent state, violating ADR-001. *Accepted cost:* eventual consistency between finalization
  and projections; scoring proceeds in the background.
- **Publish-then-write (no outbox)** — rejected: risks phantom events (published, write rolls back)
  or lost events (write commits, publish fails). *Accepted cost:* an outbox table and a dispatcher.
- **Exactly-once delivery guarantees** — rejected as impractical; we choose at-least-once delivery
  plus idempotent consumers for exactly-once *effect*. *Accepted cost:* every consumer must implement
  idempotency and a processed-event checkpoint.

## 4. Consequences

- No round can be half-scored: the domain change and its event commit together or not at all.
- Downstream contexts (Engagement, Notification) can fail, be redeployed, or be added later without
  risk to the competitive record, and can be rebuilt from retained events / the ledger.
- Every consumer carries an idempotency obligation and a checkpoint table — a fixed per-consumer
  cost.
- Event delivery latency is bounded by dispatcher polling; the deadline-time and finalization bursts
  are absorbed asynchronously, keeping request latency low (ADR-003 §2.13).
- Operational monitoring of outbox backlog and dead-letters becomes a first-class integrity signal
  (ADR-007 §2.3).

## 5. Traceability to Prior ADRs

The transactional outbox and "no half-scored round" guarantee serve Axiom 6 and ADR-002 §2.7.
Asynchronous cross-context reactions serve ADR-001 §5 and ADR-002 §2.6. Self-contained payloads and
"no back-reference into other contexts" serve ADR-002's context-isolation rule. Idempotent consumers
and processed-event checkpoints realize ADR-003 §2.9. Event schema versioning aligns with ADR-003
§2.12 and ADR-004 §2.4. Ledger-position ordering serves the append-only ledger invariant (ADR-003
§2.8).

## 6. Deferred to Downstream / Implementation

Concrete serialization format, the dispatcher's polling interval and backoff parameters, per-consumer
checkpoint table DDL, dead-letter tooling, and the exact retention window are implementation and
operational artifacts. Dispatcher deployment (worker process, leader election) is specified in
**ADR-007**; the security posture of event-carried data is covered by **ADR-006**.

---

**Ratification note.** This document is ratified as the Event Architecture layer. Any deviation
requires an amendment recorded here.
