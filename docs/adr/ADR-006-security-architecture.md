# ADR-006 — Security Architecture

**Nukhba Platform · Architectural Decision Record**
Status: **Accepted** · Version 1.0 · Date: 2026-07-08
Depends on: ADR-001 Domain · ADR-002 Application · ADR-003 Database · ADR-004 API · ADR-005 Event
(all Accepted)
Related: ADR-007 Deployment

---

## 1. Context

Security here is not a bolt-on; it is the enforcement of **Axiom 6** — the integrity of the
competitive record. That record is the asset. Points are a virtual-value instrument (ADR-001 excludes
cash but preserves the virtual-economy seam), so the threat model treats **point manipulation as the
crown-jewel attack**. This ADR defines the trust boundaries, the authentication and authorization
model, and the defenses that make integrity violations *infeasible* rather than merely *disallowed*.

The security posture is a direct consequence of decisions already ratified: backend-authoritative
writes (ADR-002), a fully-trusted service role that bypasses RLS (ADR-003 §2.10), the append-only
ledger (ADR-003 §2.8), and the transactional outbox (ADR-005). Security is the disciplined reading of
what those decisions imply.

## 2. Decision

### 2.1 Trust boundaries — exactly three zones

- **The client is untrusted.** Every input from Flutter is hostile until validated server-side.
  Nothing computed on the client is ever authoritative — this is the whole reason the legacy
  client-side scoring path is retired (ADR-002 §2.2).
- **The backend is fully trusted.** It holds the service role, bypasses RLS by design (ADR-003
  §2.10), and therefore bears total responsibility for enforcing every invariant before writing.
- **Supabase is a trusted managed dependency** for Auth, Storage, and the database — but its
  client-facing surfaces (PostgREST, Realtime) are treated as an *untrusted-client channel* guarded
  by RLS.

The single most important security consequence, recorded plainly: **because the backend bypasses RLS,
RLS cannot protect the ledger from a backend bug.** The defense is layered invariant enforcement —
application checks first, then database triggers/permission revocation as the last line (ADR-003
§2.4). Security depends on *both* layers being present; neither alone is sufficient.

### 2.2 Authentication

Authentication delegates credential handling to **Supabase Auth** (avoiding the risk of hand-rolled
credential storage), but the domain issues and validates its own session context. Every backend
request **verifies the Supabase-issued JWT server-side** before mapping it to the domain `User`.
Sessions and devices are first-class members of the Identity aggregate (ADR-003 §2.1) so revocation
is possible. **Multi-factor authentication is required for admin/service accounts**, which are the
highest-value targets (result finalization, ledger adjustments).

### 2.3 Authorization — two mandatory layers

Authorization is **two-layered, and both layers are mandatory**:

1. **Role / permission layer** — platform roles and group roles: is this identity allowed this *kind*
   of action? (Only an owner/admin may invite or change roles; only admin/service may finalize
   results or adjust the ledger — ADR-004 §2.2.)
2. **Business-invariant layer** — even a permitted role cannot submit after a deadline, cannot alter
   a frozen ruleset, cannot write to a group they've left. ADR-004 commands enforce this explicitly;
   ADR-003 triggers enforce the most catastrophic cases physically.

Admin and service-role capabilities are the **narrowest, most-audited** surface in the system.

### 2.4 The ledger and anti-fraud

The ledger's append-only, immutable design (ADR-003 §2.8) *is* the primary anti-fraud control: there
is no operation that rewrites point history, so the classic attacks — silently editing a balance,
deleting a penalty — are **impossible by construction**. Supporting controls:

- Every entry records `created_by` and `source_ref`, giving a complete, immutable audit trail.
- The scheduled `balance = SUM(entries)` **reconciliation** (ADR-003 §2.8) is a tamper-detection
  tripwire: any drift is a **Sev-1 integrity incident, never auto-corrected**.
- Manual adjustments are logged, attributed, and reversible **only by compensating entries** — even
  an admin cannot make points vanish without a trace (ADR-004 §2.2: no "set balance" / "recalculate"
  verbs exist).

### 2.5 Prediction integrity against timing attacks

The deadline is the security boundary of fairness.

- **The server clock is authoritative**; client-supplied timestamps are never trusted.
- Predictions are rejected server-side against the round's stored deadline, and the database trigger
  enforces the same on any write path (ADR-003 §2.4) — defense in depth.
- The **frozen ruleset snapshot** prevents a subtler attack: an admin (or a compromised admin
  account) changing scoring rules *after* outcomes are known to favor a participant. Because past
  rounds carry immutable snapshots (ADR-003 §2.4, §2.12), retroactive rule manipulation cannot alter
  settled results.

### 2.6 Data protection, abuse, and the social surface

- Personal data (profiles, identity) is **minimized and access-scoped by RLS** (ADR-003 §2.10).
- The **group-scoped (not open-graph) social model** (ADR-001 exclusion) bounds abuse: content is
  moderatable within known memberships rather than exposed to platform-wide discovery.
- Tier-3 surfaces (chat, memes) get **rate limiting and content-moderation hooks**; abuse there
  cannot corrupt Tier-1 truth by design (tier isolation).
- **Rate limiting at the API edge** (ADR-002/ADR-004) protects the deadline-time prediction burst
  from being weaponized and protects auth endpoints from credential-stuffing.

### 2.7 Secrets, service role, and deployment security

- The **service-role credential is the most dangerous secret** in the system — it bypasses RLS. It
  lives only in the backend's server environment (ADR-002 §2.14: only `apps/server` is built with
  it), **never in the client build, never in the repo**.
- The deployment boundary that excludes integrity-critical use-cases from the client build (ADR-002
  §2.8, §2.14) is *also* a security control: the code path to write the ledger is not shipped to
  devices.
- Secret rotation and environment isolation (dev/staging/prod, each with its own Supabase project)
  are operational requirements specified in ADR-007 §2.2.

### 2.8 Event and transport security

- All client↔backend traffic is over **HTTPS/TLS** (ADR-002 §2.1); JWTs are transmitted only over
  TLS and verified server-side per request (§2.2).
- Event payloads carried through the outbox (ADR-005) are internal to the trusted backend/database
  zone and are not exposed to the client; the client receives only Tier-3 realtime hints and reads
  authoritative state through the API (ADR-005 §2.3).

## 3. Rejected Alternatives

- **RLS as the sole security boundary** — rejected: business invariants (deadline, frozen ruleset,
  membership) need the application layer; RLS answers only "may this row be touched?" *Cost:* a
  trusted backend that must self-enforce.
- **Client-side deadline enforcement** — rejected: trivially bypassable. *Cost:* server clock is
  authoritative and every write is server-validated.
- **Mutable ledger with an audit log alongside** — rejected: an attacker who can edit truth can often
  edit the log; immutability-by-construction is strictly stronger. *Cost:* corrections are
  compensating entries, reconciliation machinery.
- **Hand-rolled authentication** — rejected in favor of Supabase Auth to avoid credential-storage
  risk. *Cost:* dependence on a managed Auth provider, verified server-side.

*Sensitive-topic note:* none applicable — this is standard platform-integrity security, not a
dual-use concern.

## 4. Consequences

- The crown-jewel asset (points) cannot be silently altered by anyone, including an admin or the
  backend, without an immutable, attributable trace and a reconciliation tripwire.
- The backend's full trust makes backend correctness a security requirement, not just a quality one —
  a backend bug is a security incident, which is why layered enforcement (app + DB) is mandatory.
- Admin/service accounts become the primary attack surface and are therefore MFA-protected and
  narrowly scoped.
- The client build cannot leak the service role or the ledger write path, at the cost of maintaining
  a strict client/server build split (ADR-007).
- Tier-3 abuse is contained and cannot escalate into Tier-1 corruption, at the cost of running
  moderation and rate-limiting infrastructure.

## 5. Traceability to Prior ADRs

The untrusted-client / trusted-backend boundary and server-side JWT verification serve Axiom 6 and
ADR-002 §2.2. Two-layered authorization realizes ADR-004 §2.1 rule 2 and ADR-003 §2.4 triggers. The
append-only ledger anti-fraud posture is ADR-003 §2.8. Server-authoritative deadline + frozen ruleset
serve the ADR-001 immutability invariants. Service-role secrecy and the client/server build split are
ADR-002 §2.14. Tier isolation of abuse follows ADR-001's capability tiering. Outbox-internal payloads
follow ADR-005 §2.3.

## 6. Deferred to Downstream / Implementation

Concrete rate-limit thresholds, MFA provider configuration, secret-rotation cadence, content-
moderation tooling, and RLS policy expressions are implementation/operational artifacts. Environment
isolation and secret provisioning per environment are specified in **ADR-007**. Incident-response
runbooks (e.g. reconciliation-drift Sev-1) are operational documents produced against ADR-007 §2.3.

---

**Ratification note.** This document is ratified as the Security Architecture layer. Any deviation
requires an amendment recorded here.
