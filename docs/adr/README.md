# Nukhba Platform — Architectural Decision Records (ADR Index)

Foundational architecture. Each ADR records decisions with rejected alternatives and consequences,
and must trace to the axioms of ADR-001. Any deviation requires an amendment recorded in the relevant
ADR.

| ADR | Title | Status | Depends on |
|---|---|---|---|
| ADR-001 | Domain Architecture | Accepted (ratified) | — |
| [ADR-002](./ADR-002-application-architecture.md) | Application Architecture | Accepted | ADR-001 |
| [ADR-003](./ADR-003-database-architecture.md) | Database Architecture | Accepted | ADR-001, ADR-002 |
| [ADR-004](./ADR-004-api-architecture.md) | API Architecture | Accepted | ADR-001, ADR-002, ADR-003 |
| [ADR-005](./ADR-005-event-architecture.md) | Event Architecture | Accepted | ADR-001, ADR-002, ADR-003 |
| [ADR-006](./ADR-006-security-architecture.md) | Security Architecture | Accepted | ADR-001–ADR-005 |
| [ADR-007](./ADR-007-deployment-architecture.md) | Deployment Architecture | Accepted | ADR-001–ADR-006 |

## Reading order

Read in numeric order. ADR-001 fixes the axioms (six ratified product decisions) and the domain
model; every downstream ADR deduces from it. ADR-002 draws the integrity boundary; ADR-003 makes the
invariants physical in the database; ADR-004 exposes them as a use-case API; ADR-005 wires the event
backbone; ADR-006 is the security reading of all the above; ADR-007 is the operational platform.

## The load-bearing axioms (ADR-001)

1. Social-first.
2. Private groups are first-class.
3. Football-focused, with one preserved result-shape seam.
4. Predict once, rank everywhere (Model B).
5. Groups are durable, competition-agnostic people-sets (leaderboard = *(audience × competition)*).
6. Integrity of the competitive record is the non-negotiable core.

> Note: ADR-001 (Domain Architecture) is ratified as the project foundation; this Phase 1 work
> produced the formal ADR-002 through ADR-007 documents that conform to and cite it.
