# Social Phase — Six-Way Review

_Phase-exit review, 2026-07-12, auditor role — by DIRECT on-disk inspection of
every Social file across all six layers (NOT trusting the prior §4 checklist,
which was one generation stale on the `apps/server` item — see SO-1 below).
Result: **GREEN**. No High or Medium defect. One **documentation** defect (SO-1)
found and fixed in `project-context.md`; the single genuinely-missing code
artifact (the Social route test) was written this session. All other findings
are info/verified-OK. Social is the 9th phase (Roadmap ADR 0008), immediately
after Groups; the next phase is Notifications._

The four product decisions (project-context §2 **Milestone (Social) — Decisions
Ratified**) are the fixed premises of this review and are NOT re-litigated:
1. v1 surface = Activity Feed (round scored / member joined / rank shift) +
   emoji Reactions only; NO free-text comments.
2. Feed = pure read projection, NO new table. Reactions = the ONE new stored
   surface (`social.reactions` in `0008_social.sql`).
3. Every social read/write is group-membership-gated, reusing the exact ratified
   `group.not_a_member` gate (no existence oracle), RLS backstop.
4. Social is Tier-3 additive: a Social failure NEVER blocks a Tier-1 core
   operation.

---

## 0. Scope verified on disk

| Layer | Files (verified present & complete — no shipped TODO / placeholder / mock) |
|---|---|
| Domain | `reaction_id.dart` (UUID-validated `EntityId`, `tryParse`; distinct type from `GroupId`/`RoundId`/`UserId`), `reaction_emoji.dart` (`ReactionKind` closed set `{like,fire,clap,laugh,sad,shock}` with stable `wireValue`; `ReactionEmoji` value object, `of`/`tryParse` — an unknown token is `social.reaction_emoji_unknown`, never stored content), `reaction.dart` (`Reaction` root: `create`/`fromStored`/`changeEmoji`; group-scoped + round-targeted + author `userId`; UTC-gated `reactedAt`; NO points field — Axiom 5, NO open-graph edge — ADR-001; `changeEmoji` preserves id + `(groupId,roundId,userId)` key so persistence is an upsert not a 2nd row). All 3 exported from `domain.dart`; tests `reaction_id_test.dart`, `reaction_emoji_test.dart`, `reaction_test.dart` |
| Contracts | `social_dto.dart` (`ReactionDto`; `RoundReactionsDto`; `ActivityEventDto` type token + nullable per-type fields omitted from JSON; `GroupActivityFeedDto` newest-first; versioned, snake_case, no leakage, no points-write field, order-significant equality); exported from `contracts.dart`; `social_dto_test.dart` |
| Application | ports `reaction_repository.dart` (`ReactionRepository`: `upsertReaction`/`findReaction`/`listReactionsForRound`/`removeReaction`), `activity_feed_reader.dart` (`ActivityFeedReader.groupActivityFeed`); `activity_event.dart` (`ActivityEventType` closed set + `ActivityEvent` read value, per-type factories); use-cases `react_to_round.dart`, `remove_reaction.dart`, `list_round_reactions.dart`, `get_group_activity_feed.dart`. All 7 social exports in `application.dart`; tests `fakes.dart`, `react_to_round_test.dart` (7), `remove_reaction_test.dart` (5), `list_round_reactions_test.dart` (5), `get_group_activity_feed_test.dart` (9) |
| Infrastructure | `postgres_reaction_repository.dart` (297 L — `@named` binding only; idempotent `INSERT … ON CONFLICT ON CONSTRAINT reactions_group_round_user_uniq DO UPDATE`; SQLSTATE→typed by explicitly-named constraints; `removeReaction` `DELETE … RETURNING id` → `Ok(bool)`), `postgres_activity_feed_reader.dart` (181 L — pure read projection, NO table; one `UNION ALL` of `member_joined` + `round_scored`, group-scoped by an `EXISTS` over `participants ∩ group_memberships`, `ORDER BY occurred_at DESC LIMIT @limit`; `rank_shift` deliberately not produced — no stored rank history). Both exported from `infrastructure.dart`; `postgres_reaction_repository_test.dart` (20, hermetic) + `postgres_activity_feed_reader_test.dart` (10, hermetic) + `postgres_social_repositories_integration_test.dart` (DB-gated, tagged `integration`, skipped locally) |
| Migration | `supabase/migrations/0008_social.sql` (192 L — `social` schema, `social.reaction_kind` enum, `social.reactions` table with named FK + unique constraints, member-scoped self-read RLS, client-write revocation, anon denied; reuses `identity.set_updated_at`; the feed needs NO table — decision #2) |
| Server | `routes/groups/[id]/rounds/[roundId]/reactions/index.dart` (125 L — PUT react / DELETE remove-own / GET list / 405), `routes/groups/[id]/feed/index.dart` (59 L — GET feed with optional `?limit=` / 405); `lib/http/social_dto_mapper.dart`; CompositionRoot wires all 4 social use-cases (`bootstrap` real `PostgresReactionRepository` + `PostgresActivityFeedReader`; `forTesting` `_absent*` + `_UnwiredReactionRepository` + `_UnwiredActivityFeedReader`); `test/routes/social_routes_test.dart` (NEW this session) over `InMemoryReactionRepository` + `InMemoryActivityFeedReader` + `InMemoryGroupRepository` in `competition_route_harness.dart` |

---

## 1. Architecture

- **Clean-Architecture dependency rule (ADR 0007) honoured.** No new internal
  package: the `social` slice lives inside the existing `domain`/`contracts`/
  `application`/`infrastructure`/`apps.server` packages. Domain imports only
  `shared` + domain-internal ids (`group` `GroupId`, `competition` `RoundId`,
  `identity` `UserId`); application imports `domain`/`shared` only; the adapters
  import `application`/`domain`/`shared` + the `postgres` driver; the ONLY
  component touching `infrastructure` is `CompositionRoot`. `tooling/import_lint`
  ruleset is unchanged (no new package directory, no cross-context internal
  import — verified).
- **Tier-3 classification honoured physically (ADR 0003 §3 / ADR 0007 §Tier-3).**
  The Activity Feed adds NO writable table — it is a live `UNION ALL` projection
  over existing ratified surfaces (`group.group_memberships`, `competition.rounds`),
  so it is rebuildable and never a source of truth (decision #2). The ONE new
  stored surface is `social.reactions`, peripheral content carrying no points.
- **Decision #1 (no group ref on any core object) honoured physically.** No
  `groupId`/social column was added to any Round/Prediction/Leaderboard object —
  verified by grep across the competition/prediction/leaderboard packages +
  migrations 0002–0006 (untouched). The ONLY link is FROM social TO competition
  (a reaction's `round_id` FK, and the feed reader reading scored rounds) — never
  the reverse.
- **No open-graph edge (ADR-001 / ADR-006 §2.6).** Social is strictly
  group-scoped: a reaction and a feed event are visible only within a private
  group's membership. There is no follow/friend edge anywhere in the domain,
  DTOs, schema, or routes (verified).
- **Event-driven boundary respected.** Social adds no async dispatcher; every
  operation is a synchronous, server-authorized, in-process use-case — the
  discipline ratified since Ledger. `rank_shift` events are deliberately NOT
  synthesized (no stored rank history; the leaderboard is a live projection) —
  the `ActivityEventType.rankShift` shape exists so future work is purely
  additive, never faked (SO-note, §7).

**Finding:** none beyond SO-1 (documentation, §7).

## 2. Security

- **Trust zones (ADR 0005) honoured.** Every reaction write is server-authorized
  inside a use-case; the client is never trusted. The author `userId` is taken
  from the **verified token** (`principal.userId`), NEVER the request body —
  verified in `react_to_round.dart` (create + change) and `remove_reaction.dart`
  (removes only the caller's own row). A caller can neither react as someone else
  nor delete another member's reaction.
- **Two-layer authorization, correctly separated.** Layer 1 = platform authority
  (`Authorization.requireRole(principal, PlatformRole.user)` — any signed-in
  user, Axiom 1 social-first). Layer 2 = the per-group membership gate, enforced
  *in the use-case* via `GroupRepository.findMembership` — the EXACT ratified
  Groups gate reused, not a new mechanism (decision #3). **Verified correct** in
  all four use-cases (`react_to_round`, `remove_reaction`, `list_round_reactions`,
  `get_group_activity_feed`): each refuses a non-member `group.not_a_member`.
- **No existence oracle (decision #3) — verified end-to-end.** A non-member and
  an *absent* group are refused **identically** as `401 group.not_a_member` on
  every social read and write (the membership lookup returns null in both cases;
  no group/round existence is probed before the gate). Route tests assert the
  non-member refusal on all four surfaces.
- **RLS backstop (Axiom 6) correct.** `0008_social.sql` enables RLS on
  `social.reactions`, GRANTs only `select` to `authenticated`, and REVOKEs
  `insert/update/delete/truncate` from `anon, authenticated` — with no permissive
  write policy, all client writes are denied (backend service role owns writes).
  The self-read policy `reactions_select_member` is member-scoped (an EXISTS over
  `"group".group_memberships` correlated to `auth.uid()`, reusing the Groups
  self-join), and `anon` is denied. A client can therefore never see a reaction
  in a group they are not in — the RLS mirrors the app gate as the last line.
- **Bounded emoji set — nothing to moderate (decision #1).** `ReactionEmoji.tryParse`
  admits only the closed `ReactionKind` set; an arbitrary glyph/unknown token is
  a typed `social.reaction_emoji_unknown` validation failure, never stored. There
  is no free-text path, so there is no user-generated content to moderate in v1.
- **`@named` binding only** across both adapters (Security ADR §2) — no string
  interpolation of user input into SQL. **Verified** by reading every SQL constant
  + `parameters:` map in `postgres_reaction_repository.dart` and
  `postgres_activity_feed_reader.dart`.

**Finding:** none. S-verified (info) recorded in §7.

## 3. Correctness

- **Idempotent react = one row (decision #2).** `ReactToRound` finds an existing
  reaction and `changeEmoji`s it in place (preserving id + the `(groupId,roundId,
  userId)` key) else creates a new one; the adapter's `INSERT … ON CONFLICT ON
  CONSTRAINT reactions_group_round_user_uniq DO UPDATE SET emoji, reacted_at`
  guarantees a swap is a single-row update, never a 2nd row. A lost concurrent
  race surfaces as `social.reaction_conflict` and is resolved by re-reading the
  winning row and re-applying the caller's emoji — the caller still gets a
  successful, idempotent result. **Verified** in the use-case + `_resolveConflict`
  and by the route test's "re-react swaps in place — still one row" case.
- **Idempotent remove.** `RemoveReaction`/adapter `DELETE … RETURNING id` returns
  `Ok(true)` when a row was removed and `Ok(false)` when none existed — removing
  an absent reaction is a no-op success, not an error. Route test covers both.
- **Feed is newest-first + bounded (decision #4).** The reader's SQL orders
  `occurred_at DESC` and caps at `@limit`; `GetGroupActivityFeed._clampLimit`
  forces `[1, maxLimit=200]` with null/non-positive → `defaultLimit=50`, so an
  untrusted `?limit=` can never trigger an unbounded scan. The route passes a
  non-integer `?limit=` through as `null` (`int.tryParse`), which the clamp
  treats as absent. **Verified** by the four limit-clamp route tests asserting the
  value reaching the in-memory reader (10 / maxLimit / defaultLimit ×2).
- **Feed group-scoping is physical.** The `round_scored` branch is gated by an
  `EXISTS` over `competition.participants ∩ "group".group_memberships`, so only
  rounds relevant to the group's circle appear; the `member_joined` branch reads
  the group's own memberships. A scored round of a season no group member plays
  is excluded (documented in the integration test).
- **Row-corruption discipline.** Every adapter read maps a malformed/absent
  column or unknown enum token to transient `social.row_corrupt` (never a raw
  invariant leak on a read path) — 6 branches in the reaction reader, 4 in the
  feed reader (incl. the `rank_shift` discriminator the reader never emits), all
  covered by the hermetic tests.
- **HTTP status mapping correct.** `authorization → 401`, `validation → 400`,
  `invariant → 409`, `transient → 503` (single-place `error_envelope.dart`),
  matching the route-test assertions (non-member `401 group.not_a_member`,
  unknown emoji `400 social.reaction_emoji_unknown`, malformed group id `400`,
  transient storage `503`).
- **DTO shaping is single-place + leak-free.** `social_dto_mapper.dart` is the
  only place a `Reaction`/`ActivityEvent` becomes wire JSON: emoji + event type
  cross as stable `wireValue` tokens, timestamps as UTC ISO-8601, and no
  points/open-graph field is ever emitted. The route test asserts the absence of
  a `points` key on a reaction.

**Finding:** none. C-verified (info) recorded in §7.

## 4. Performance

- **Writes are single indexed statements.** `upsertReaction` is one
  `INSERT … ON CONFLICT` on the unique `(group_id, round_id, user_id)`;
  `removeReaction` is one `DELETE … RETURNING`; `findReaction` is one unique
  lookup. All O(1) on the natural key.
- **`listReactionsForRound`** is one `(group_id, round_id)` scan ordered by
  `reacted_at` — bounded by a round's membership; fine at v1 scale.
- **The feed is one round-trip, always capped.** A single `UNION ALL` with a hard
  `LIMIT @limit` (≤ 200) — a Tier-3 read can never over-scan (decision #4). No
  materialized table, no second copy of any data — the same read-time-assembly
  trade-off ratified for Leaderboards. **P-note (info)**, §7: the feed's per-branch
  scans are un-indexed beyond the existing PK/unique keys; acceptable at v1 scale,
  a localized index is a future optimization only if a scale phase proves it hot.

**Finding:** none blocking.

## 5. Maintainability

- **Mirrors the established house style** at every layer (group/leaderboard/
  ledger): `tryParse` ids, closed-set enums with `wireValue`, total adapters that
  never throw, single-place DTO mapper, `_absent*`/`_Unwired*` test stand-ins that
  fail loudly. A reader who knows Groups can navigate Social immediately.
- **Invariants encoded as types.** `ReactionEmoji` closed set, distinct
  `ReactionId`, UTC-gated `reactedAt`, `changeEmoji` key-preservation. Illegal
  states are largely unrepresentable; there is no free-text field to validate.
- **Explicitly-named DB constraints documented as a contract** in both the
  migration header and the adapter dartdoc — the SQLSTATE→typed mapping depends on
  those names, and both places say so. **M-note (info)**, §7.
- **`rank_shift` deliberately deferred, not faked.** The type exists across
  domain/contracts so future work is additive; the reader documents why it emits
  none today (no stored rank history). This is honest incompleteness, not a
  placeholder — SO-note, §7.

**Finding:** none. M-note (info) recorded in §7.

## 6. Production-readiness

- **No shipped placeholders/TODOs/mocks** — verified by grep across every Social
  lib file (`packages/**/social/**`, `packages/**/*social*`, `apps/server/**`
  social routes + mapper, the migration). The only "placeholder" string is a
  dartdoc word in the feed reader explaining `rank_shift` is a *shape* reserved
  for future additive work (not shipped placeholder code). The only in-memory
  fakes live under `test/` (the harness + application fakes), as intended.
- **Migration is forward-only + idempotent** — `create schema/type/table if not
  exists`, `create or replace function` (reused `identity.set_updated_at`),
  `drop … if exists` before every policy/trigger. Safe to re-run; expand-only.
- **CompositionRoot wiring is real and complete.** `bootstrap` constructs
  `PostgresReactionRepository` + `PostgresActivityFeedReader` and wires all 4
  social use-cases (reactions reuse the ratified `GroupRepository` for the member
  gate); `forTesting` supplies loud `_absent*` stand-ins backed by
  `_UnwiredReactionRepository` (full port, every method throws) +
  `_UnwiredActivityFeedReader`. The private constructor's 4 social params are all
  backed by fields and supplied by both `bootstrap` and `forTesting` — the file
  is a coherent graph.
- **No new external dependency** (§3) — reuses `postgres 3.5.12`,
  `dart_frog 1.2.6`, `mocktail`, `test ^1.26.0`.
- **Tests at every layer** — domain (3 files), contracts (1), application (4 use
  cases, 26 cases + fakes), infrastructure hermetic (20 + 10) + integration
  (DB-gated), route (this session: both routes, every gate, the feed `?limit=`
  clamp, idempotent swap/remove, empty-list legitimacy, transient-503,
  405-per-method).

**Finding:** none.

---

## 7. Summary of findings

| ID | Severity | Area | Status |
|---|---|---|---|
| SO-1 | **Documentation (not code)** | SSoT drift — §4 recorded the `apps/server` Social item as `[ ]` NOT STARTED, but the mapper + both route files + CompositionRoot wiring + harness in-memory repos were COMPLETE and CORRECT on disk (the recurring "code shipped, docs untouched" pattern, now the 5th time). The single genuinely-missing artifact was the route test. | **Fixed** — the route test `apps/server/test/routes/social_routes_test.dart` was written this session (+ a `wireContext` `uri`/`queryParameters` stub in the harness so the feed `?limit=` is exercisable); §2 delivery record + §4 checklist corrected to `[x]`. The on-disk routes/mapper/wiring required NO code change (already production-correct). |
| SO-note | Info | `rank_shift` feed events are not synthesized (no stored rank history; the leaderboard is a live projection). | Deliberate, documented; the `ActivityEventType.rankShift` shape exists so future work is purely additive, never faked. No change. |
| P-note | Info | Performance — feed per-branch scans un-indexed beyond existing PK/unique keys | Ratified v1 read-time-assembly trade-off; always `LIMIT`-capped ≤ 200 so it stays cheap. Optimize only if a scale phase proves it hot. No change. |
| M-note | Info | Maintainability — named-constraint↔adapter coupling | Intentional + documented in both the migration and the adapter; matches group/ledger/scoring style. No change. |
| S-verified | Info | Security — token-sourced authorship, no existence oracle, member-scoped RLS + anon-deny + write-revocation backstop, `@named` binding, closed emoji set (nothing to moderate) | Verified OK across use-cases + migration + adapters; no change. |
| C-verified | Info | Correctness — idempotent react (one-row swap) + race convergence, idempotent remove, newest-first + clamped feed, physical feed group-scoping, row_corrupt discipline, status mapping, leak-free DTO shaping | Verified OK by domain/application/adapter/route tests + on-disk SQL; no change. |

**No High or Medium defect. The single defect (SO-1) is a documentation drift in
the SSoT plus one missing test file; the on-disk production code required no
change.**

## 8. Exit criterion

**MET.** The Social (Tier-3) surface is delivered end-to-end at full Milestone-0
rigor across all six layers: a group member reacts to a round-result with a
bounded emoji (or swaps it in place — one row), removes their own reaction
idempotently, and lists a round's reactions; any member reads their group's
activity feed (member-joined + round-scored events, newest-first, bounded) — all
behind `bearerAuth`, all gated to group membership with NO existence oracle, and
a non-member is refused identically everywhere. The four ratified product
decisions are honoured physically (Feed + emoji reactions only, no free text;
feed = pure projection with NO table + reactions the ONE stored surface;
`group.not_a_member` gate + RLS backstop reused unchanged; Social is additive
and never blocks a Tier-1 core operation). Axioms 1/2/5/6 and ADR-001/ADR-006
§2.6 are honoured physically (social-first but group-scoped, server-only writes,
NO second points source, NO open-graph edge, member-scoped RLS + write
revocation as the backstop; NO group ref on any core object). No new external
dependency; `tooling/import_lint` ruleset unchanged. **Six-way review GREEN —
Social phase COMPLETE & RATIFIED. Next phase per Roadmap ADR 0008:
Notifications.**
