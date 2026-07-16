# Groups Phase — Six-Way Review

_Phase-exit review, 2026-07-12, auditor role — by DIRECT on-disk inspection of
every Groups file across all six layers (not trusting the prior §4 checklist,
which was one generation stale — see G-1 below). Result: **GREEN**. No High or
Medium defect. One **documentation** defect (G-1) found and fixed in
`project-context.md`; all other findings are info/verified-OK. Groups is the 8th
phase (Roadmap ADR 0008), immediately after Leaderboards; the next phase is
Social._

The four product decisions (project-context §2 **Milestone (Groups) — Decisions
Ratified**) are the fixed premises of this review and are NOT re-litigated:
1. Group ⊥ Competition (no `groupId` on any competition/round/prediction/
   leaderboard surface).
2. Roles = `owner`/`member` only; join = shareable invite code, instant
   zero-friction; `GroupMembership` independent of competition `Participant`.
3. Private-by-default, invite-only, no existence oracle for non-members.
4. Group leaderboard reuses `leaderboard.season_standings` filtered to group
   membership — no new points source, no new ranking logic.

---

## 0. Scope verified on disk

| Layer | Files (verified present & complete — no TODO / placeholder / mock) |
|---|---|
| Domain | `group_id.dart`, `group_membership_id.dart` (UUID-validated `EntityId`s, `tryParse`), `group_role.dart` (closed set `{owner, member}`, NO admin tier — decision #2), `invite_code.dart` (fixed length 10, closed URL-safe alphabet excluding ambiguous `0 O 1 I L` + lower-case; `alphabet`/`isAllowedChar`/`codeLength` so the app generator draws exactly the validated shape), `group.dart` (`Group` root: `create` name-trim 1–80 mirroring `Competition.create`, UTC `createdAt`; `fromStored`/`rename`/`regenerateInvite`; NO competition ref — decision #1), `group_membership.dart` (`owner`/`join` factories UTC-gated, `fromStored`, `isOwner`; independent of `Participant` — decision #2). All 6 exported from `domain.dart`; tests `group_id_test.dart`, `group_role_test.dart`, `invite_code_test.dart`, `group_test.dart`, `group_membership_test.dart` |
| Contracts | `group_dto.dart` (`GroupDto` id/name/owner_id/invite_code/created_at/member_count; `GroupMembershipDto`; `GroupMembersDto`; `GroupLeaderboardEntryDto` + `GroupLeaderboardDto`; versioned, snake_case, no leakage, order-significant equality); exported from `contracts.dart`; `group_dto_test.dart` |
| Application | ports `group_repository.dart` (`GroupRepository`: `createGroupWithOwner`/`findGroup`/`findByInviteCode`/`updateGroup`/`saveMembership`/`findMembership`/`listMemberships`), `group_standings_reader.dart` (`GroupStandingsReader.groupSeasonStandings` + `GroupStandingEntry`); `common/invite_code_generator.dart` (`InviteCodeGenerator` port); use-cases `create_group.dart`, `join_group_by_invite.dart`, `get_group.dart` (+ `GroupWithMemberCount`), `rename_group.dart`, `regenerate_invite.dart`, `list_group_members.dart`, `get_group_leaderboard.dart` (+ `group_leaderboard.dart`: `RankedGroupStanding`/`GroupLeaderboard`). All 10 group exports in `application.dart`; tests `fakes.dart`, `create_group_test.dart` (6), `join_group_by_invite_test.dart` (7), `rename_and_regenerate_test.dart` (8), `list_group_members_test.dart` (5), `get_group_leaderboard_test.dart` (6) |
| Infrastructure | `postgres_group_repository.dart` (526 L — implements BOTH `GroupRepository` AND `GroupStandingsReader`; `@named` binding only; atomic `createGroupWithOwner` via `runInTransaction`; SQLSTATE→typed by explicitly-named constraints; season∩membership standings read over the reused VIEW); exported from `infrastructure.dart`; `postgres_group_repository_test.dart` (32, hermetic) + `postgres_group_repository_integration_test.dart` (DB-gated, tagged `integration`, skipped locally) |
| Migration | `supabase/migrations/0007_group.sql` (252 L — `group` schema, `group.group_role` enum, `groups` + `group_memberships` tables, member-scoped self-read RLS, client-write revocation, anon denied; reuses `identity.set_updated_at`) |
| Server | `routes/groups/` all 7: `_middleware.dart` (`bearerAuth` on the subtree), `index.dart` (POST create), `join/index.dart` (POST join), `[id]/index.dart` (GET read + PATCH rename), `[id]/members/index.dart` (GET roster), `[id]/invite/regenerate/index.dart` (POST rotate), `[id]/seasons/[seasonId]/leaderboard/index.dart` (GET group board); `lib/http/group_dto_mapper.dart`; CompositionRoot wires all 7 group use-cases (`bootstrap` real `PostgresGroupRepository` + `UuidInviteCodeGenerator`, the same repo instance backing both group ports; `forTesting` `_absent*` + `_UnwiredGroupRepository` implementing both ports + `_UnwiredInviteCodeGenerator`); `test/routes/group_routes_test.dart` (30) over `InMemoryGroupRepository` + `InMemoryGroupStandingsReader` in `competition_route_harness.dart` |

---

## 1. Architecture

- **Clean-Architecture dependency rule (ADR 0007) honoured.** No new internal
  package: the `group` slice lives inside the existing `domain`/`contracts`/
  `application`/`infrastructure`/`apps.server` packages. Domain imports only
  `shared` + domain-internal `identity` (`UserId`); application imports
  `domain`/`shared` only; the adapter imports `application`/`domain`/`shared` +
  the `postgres` driver; the ONLY component touching `infrastructure` is
  `CompositionRoot`. `tooling/import_lint` ruleset is unchanged (verified: no new
  package directory, no cross-context internal import).
- **Decision #1 (Group ⊥ Competition) honoured physically.** `group.groups`
  carries NO season/competition/round column; `0007_group.sql` references the
  competition schema ONLY in the read-only standings intersection (a SELECT over
  the reused VIEW), never as an FK on a group object. No `groupId` was added to
  any Round/Prediction/Leaderboard surface (verified by grep across the
  competition/prediction/leaderboard packages + migrations 0002–0006 — untouched).
- **Event-driven boundary respected.** Groups add no async dispatcher; every
  operation is a synchronous, server-authorized, in-process use-case — the same
  discipline ratified for Ledger/Leaderboards. The group leaderboard is a pure
  read-side projection (decision #4), introducing no second write path.
- **Aggregate boundaries correct.** `Group` and `GroupMembership` are separate
  aggregates (mirror of `Competition ⟂ Participant`), so a large membership set
  never locks the group row; the owner membership is created atomically with the
  group via one transaction (a group can never exist without its owner).

**Finding:** none beyond G-1 (documentation, §7).

## 2. Security

- **Trust zones (ADR 0005) honoured.** Every write is server-authorized inside a
  use-case; the client is never trusted. `ownerId` (create) and `userId` (join)
  come from the **verified token** (`principal.userId`), NEVER the request body —
  verified in `create_group.dart` and `join_group_by_invite.dart`. A caller can
  neither create a group owned by someone else nor enrol a third party.
- **Two-layer authorization, correctly separated.** Layer 1 = platform authority
  (`Authorization.requireRole(principal, PlatformRole.user)` — any signed-in
  user). Layer 2 = the per-group `GroupRole`, enforced *in the use-case* (an
  aggregate cannot see the principal): rename/regenerate require `owner`
  (`group.not_owner`); reads require membership (`group.not_a_member`). The
  per-group role is deliberately distinct from the platform-wide `PlatformRole` —
  "platform admin" is irrelevant to owning a private social circle. **Verified
  correct** in `rename_group.dart`, `regenerate_invite.dart`, `get_group.dart`,
  `list_group_members.dart`, `get_group_leaderboard.dart`.
- **No existence oracle (decision #3) — verified end-to-end.** A non-member and an
  *absent* group are refused **identically** as `401 group.not_a_member` on every
  member-gated read; an unknown/rotated invite code is `409 group.invite_invalid`
  identically whether or not a group exists. A storage inconsistency (membership
  row present, group row absent) is also reported as `not_a_member` — no partial
  group is fabricated and no existence signal leaks. Route tests assert the
  "absent group refused identically" case explicitly.
- **RLS backstop (Axiom 6) correct.** `0007_group.sql` enables RLS on both
  tables, GRANTs only `select` to `authenticated`, and REVOKEs
  `insert/update/delete/truncate` from `anon, authenticated` — with no permissive
  write policy, all client writes are denied (backend service role owns writes).
  The self-read policies are member-scoped (`groups_select_member` via an EXISTS
  over `group_memberships`; `group_memberships_select_comember` via a correlated
  self-join on `auth.uid()`), and `anon` is denied on both (`using (false)`). A
  client can therefore never enumerate or observe a group they are not in — the
  RLS mirrors the app gate as the last line of defence.
- **Invite code is server-owned + crypto-strong.** Generated only via
  `InviteCodeGenerator` (`UuidInviteCodeGenerator`, `Random.secure()` — §3),
  never client-supplied; `InviteCode.tryParse` validates a closed charset+length
  so an untrusted join token is a typed validation failure, not a lookup on
  arbitrary input. Rotation revokes the old link (the old code stops resolving).
- **`@named` binding only** across the adapter (Security ADR §2) — no string
  interpolation of user input into SQL. **Verified** by reading every SQL
  constant + `parameters:` map in `postgres_group_repository.dart`.

**Finding:** none. S-verified (info) recorded in §7.

## 3. Correctness

- **Atomic create.** `createGroupWithOwner` writes the group row then the owner
  membership inside one `runInTransaction`; a failed group insert short-circuits
  before the membership insert, a failed membership insert rolls back the group —
  proven by the hermetic adapter test's ordered-writes + short-circuit cases and
  documented for the live rollback in the integration test.
- **Idempotent join with concurrent-race convergence.** `JoinGroupByInvite`
  resolves the group by code, returns the existing membership if already a member
  (covers the owner joining their own code), else inserts; a lost race surfaces as
  `group.already_member` (the pivot the adapter maps `group_memberships_group_user_uniq`
  to) and is resolved by re-reading the winning row — mirror of `JoinCompetition`.
  Verified in `join_group_by_invite.dart` + `_resolveConflict`, exercised by the
  "re-join returns one membership" route test.
- **Group leaderboard re-key is sound (decision #4).** `GetGroupLeaderboard`
  reads the unranked group∩season projection, ranks the underlying
  `LeaderboardEntry`s with the **pure domain** `SeasonLeaderboard.rank` (the
  IDENTICAL "1224" rule + points-desc/joinedAt-asc/id-asc tie-break used for the
  season board — so a group board can never disagree with the season board for
  the members it shows), then re-attaches each member's `UserId` to its ranked
  entry keyed on the stable `participantId`. The reader guarantees one entry per
  participant, so the lookup is unambiguous; a ranked participant that cannot map
  back to a member is surfaced as transient `group.standings_inconsistent` rather
  than fabricated — a read path never lies about ownership. **Verified correct**;
  the "1224 tie sharing rank 2" and "empty board 200" route tests cover it.
- **Standings intersection query correct.** The adapter's
  `_selectGroupSeasonStandingsSql` joins `leaderboard.season_standings` →
  `competition.participants` → `group.group_memberships`, filtered by
  `@season_id` + `@group_id`, with NO ORDER BY (the domain owns ordering). A user
  appears only if they are BOTH a group member AND a season participant of that
  season — exactly decision #4's intersection semantics; the VIEW already scopes
  the SUM to the season and nets in corrections (Axiom 5), so totals match the
  member's balance read.
- **Row-corruption discipline.** Every adapter read maps a malformed/absent
  column to transient `group.row_corrupt` (never a raw invariant leak on a read
  path) — 4 branches for `findGroup`/`findByInviteCode` and 5 for
  `groupSeasonStandings`, all covered by the hermetic test.
- **HTTP status mapping correct.** `authorization → 401`, `validation → 400`,
  `invariant → 409`, `transient → 503` (single-place `error_envelope.dart`),
  matching the phase's route-test assertions (e.g. non-owner `401 group.not_owner`,
  malformed name `400`, unknown code `409`, transient storage `503`).

**Finding:** none. C-verified (info) recorded in §7.

## 4. Performance

- **Reads are single round-trips.** `findGroup`/`findByInviteCode`/`findMembership`
  are single indexed lookups (PK / `groups_invite_code_key` unique /
  `group_memberships_group_user_uniq` unique). `listMemberships` is a single
  by-group read served by the unique `(group_id, user_id)`; the added
  `group_memberships_user_idx` serves the RLS "which groups am I in" subquery and
  the membership lookup by user.
- **`GetGroup` issues 3 reads** (membership gate + group + roster-for-count). This
  is deliberate and ADR-neutral — the member count is not carried on the aggregate
  (a group is orthogonal to its membership rows, decision #1). Fine at v1 scale; a
  future `SELECT count(*)` push-down or a cached count is a localized optimization
  if a scale phase shows it hot. **P-note (info)**, §7.
- **Rename/regenerate re-read for the member count** (the follow-on member-gated
  `getGroup`). Same rationale as above — a rename/rotation does not change the
  count, and the re-read is the caller-visible-count source of truth; the fallback
  to `memberCount: 1` on a concurrent deletion still reports the successful write.
  Acceptable at v1 scale. **P-note (info)**, §7.
- **Group standings** = one intersection SELECT over the ratified VIEW; ranking is
  in-memory in the pure domain. No materialized table, no second points copy
  (decision #4) — the same read-time-aggregation trade-off ratified for
  Leaderboards.

**Finding:** none blocking.

## 5. Maintainability

- **Mirrors the established house style** at every layer (competition/leaderboard/
  ledger): `tryParse` ids, closed-set enums with `wireValue`, total adapters that
  never throw, single-place DTO mapper, `_absent*`/`_Unwired*` test stand-ins that
  fail loudly. A reader who knows a prior phase can navigate Groups immediately.
- **The invariants are encoded as types** (Axiom-2 first-class community):
  `InviteCode` shape, `GroupRole` closed set, UTC-gated timestamps, name length in
  `Group.create`. Illegal states are largely unrepresentable.
- **Explicitly-named DB constraints are documented as a contract** in both the
  migration header and the adapter dartdoc — the SQLSTATE→typed mapping depends on
  those names, and both places say so (they must not be renamed independently).

**Finding:** none. M-note (info) recorded in §7.

## 6. Production-readiness

- **No placeholders/TODOs/mocks in shipped code** — verified by grep across every
  Groups lib file (`packages/**/group/**`, `apps/server/**/group*`, the migration).
  The only in-memory fakes live under `test/` (the harness + application fakes),
  as intended.
- **Migration is forward-only + idempotent** — `create schema/type/table if not
  exists`, `create or replace function` (reused), `drop … if exists` before every
  policy/trigger. Safe to re-run; expand-only (Platform ADR).
- **CompositionRoot wiring is real and complete** (see G-1): `bootstrap`
  constructs one `PostgresGroupRepository` (backing BOTH group ports) +
  `UuidInviteCodeGenerator`, and wires all 7 use-cases; `forTesting` supplies loud
  stand-ins for every un-exercised group slice. The file compiles as a coherent
  graph (the private constructor's 7 group params are all backed by fields and all
  supplied by both `bootstrap` and `forTesting`).
- **No new external dependency** (§3) — reuses `postgres 3.5.12`,
  `dart_frog 1.2.6`, `mocktail`, `test ^1.26.0`, and `dart:math` `Random.secure`.
- **Tests at every layer** — domain (5 files), contracts (1), application (6),
  infrastructure hermetic (32) + integration (DB-gated), route (30). Coverage
  spans every gate, idempotency path, no-existence-oracle case, "1224" ranking,
  empty board, and 405-per-method.

**Finding:** none.

---

## 7. Summary of findings

| ID | Severity | Area | Status |
|---|---|---|---|
| G-1 | **Documentation (not code)** | SSoT drift — §4 recorded the `apps/server` CompositionRoot Groups wiring as "NOT STARTED (reverted)", but it is COMPLETE and CORRECT on disk (all 7 use-cases wired in `bootstrap` + `forTesting` + both `_Unwired*` stand-ins). The recurring "code shipped, docs untouched" pattern, now the 4th time. | **Fixed** — §2 delivery record + §4 checklist corrected to `[x]`; the review confirms the on-disk wiring is production-correct. NO code change (the code was already right). |
| P-note | Info | Performance — `GetGroup` 3 reads / rename+regenerate re-read for member count | Ratified v1 trade-off (count not on the aggregate — decision #1); optimize only if a scale phase proves it hot. No change. |
| M-note | Info | Maintainability — named-constraint↔adapter coupling | Intentional + documented in both places; matches ledger/scoring style. No change. |
| S-verified | Info | Security — token-sourced identity, no existence oracle, member-scoped RLS + anon-deny + write-revocation backstop, `@named` binding, crypto-strong server-owned invite code | Verified OK across use-cases + migration + adapter; no change. |
| C-verified | Info | Correctness — atomic create, idempotent join + race convergence, group-board re-key against the pure-domain "1224" rank, season∩membership intersection, row_corrupt discipline, status mapping | Verified OK by domain/application/adapter/route tests + on-disk SQL; no change. |

**No High or Medium defect. The single defect (G-1) is a documentation drift in
the SSoT, corrected in `project-context.md`; the code required no change.**

## 8. Exit criterion

**MET.** The `Group` (Community) aggregate is delivered end-to-end at full
Milestone-0 rigor across all six layers: a signed-in user creates a private group
(owner membership written atomically) and shares an unguessable invite code; any
user joins zero-friction and idempotently via that code; owners rename the group
and rotate the code (revoking a leaked link); members read the group, its roster,
and its season leaderboard; a non-member is refused with no existence oracle
anywhere. The four ratified product decisions are honoured physically (Group ⊥
Competition, owner/member roles only, private/invite-only, group board = the
reused season-standings VIEW ∩ membership with no new points source). Axioms
1/2/5/6 are honoured physically (social-first private community, first-class from
the root, a single protected truth for points, member-scoped RLS + write
revocation as the backstop). No new external dependency; `tooling/import_lint`
ruleset unchanged. **Six-way review GREEN — Groups phase COMPLETE & RATIFIED. Next
phase per Roadmap ADR 0008: Social.**
