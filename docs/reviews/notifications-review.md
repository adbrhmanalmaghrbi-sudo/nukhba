# Notifications Phase — Six-Way Review

_Phase-exit review, 2026-07-13, auditor role — by DIRECT on-disk inspection of
every Notifications file across all six layers plus the `apps/server` wiring
(NOT trusting the §4 checklist). Result: **GREEN**. No High or Medium defect.
No code change was required this session — every layer was verified
already-correct on disk (including the session-42 compile break, confirmed
FIXED and correct at the `CompositionRoot._(...)` call site). All findings are
info/verified-OK. Notifications is the 10th phase (Roadmap ADR 0008),
immediately after Social; the next phase is Admin Panel._

The four product/architecture decisions (project-context §2 **Milestone
(Notifications) — Decisions Ratified**) are the fixed premises of this review
and are NOT re-litigated:
1. Trigger surface = exactly three kinds `{round_scored, group_member_joined,
   reaction_received}`, all derived from already-ratified events; a full
   enumeration is explicitly rejected for v1.
2. Delivery channel = in-app / in-platform list ONLY (no push / email / SMS) —
   so NO new external dependency and NO PII surface.
3. Genuinely STORED, per-user, MUTABLE read-state — its own table
   `notification.notifications` (unlike Social's pure-projection feed).
4. Strictly RECIPIENT-ONLY visibility — the gate is "caller == recipient", NOT
   group-membership; a foreign/unknown id is refused identically
   (`notification.not_found`) with NO existence oracle; writes are server-only.

---

## 0. Scope verified on disk

| Layer | Files (verified present & complete — no shipped TODO / placeholder / mock) |
|---|---|
| Domain | `notification_id.dart` (UUID-validated `EntityId`, `tryParse`; distinct type from `UserId`/`RoundId`/`GroupId`/`ReactionId`), `notification_kind.dart` (`NotificationKind` closed 3-set with stable `wireValue` {round_scored, group_member_joined, reaction_received} + total `tryParse` → `notification.kind_unknown`), `notification_subject.dart` (`NotificationSubject` value object: per-kind named factories, deterministic `dedupeRef` `round:<id>` / `group_join:<g>:<a>` / `reaction:<g>:<r>:<a>`; NO points, NO free text), `notification.dart` (`Notification` root: `create`/`fromStored`/`markRead`; recipient-scoped; subject-kind match enforced; UTC-gated `createdAt`/`readAt`; `markRead` idempotent — already-read returns `this`, preserving the original timestamp; NO points field — Axiom 5, NO open-graph edge — ADR-001; only mutable state is `readAt`). All 4 exported from `domain.dart`; tests `notification_id_test.dart`, `notification_kind_test.dart`, `notification_subject_test.dart`, `notification_test.dart` |
| Contracts | `notification_dto.dart` (`NotificationDto` id/recipient_id/kind token/read/created_at + nullable read_at/round_id/group_id/actor_user_id omitted-when-null; `NotificationListDto` recipient_id + newest-first notifications + unread_count; versioned, snake_case, no leakage, NO points-write field, value equality); exported from `contracts.dart`; `notification_dto_test.dart` |
| Application | port `ports/notification_repository.dart` (`NotificationRepository`: `createIfAbsent` idempotent on `(recipientId, kind, dedupeRef)` → `Ok(created?)`; `listForRecipient` newest-first clamped; `findForRecipient` → `Ok(null)` foreign/absent; `markRead` → `Ok(true/false/null)`; `unreadCount`); `create_notification.dart` (`CreateNotification` server-side idempotent facade — NOT client-callable, no self-role gate); the 3 trigger commands `notify_round_scored.dart` / `notify_group_member_joined.dart` (owner-target) / `notify_reaction_received.dart` (self-reaction suppressed); recipient-only reads/mark `list_my_notifications.dart` (clamp `[1,200]`, default 50), `get_unread_count.dart`, `mark_notification_read.dart` (foreign/unknown → `notification.not_found`, no oracle). All 7 + the port exported from `application.dart`; tests `fakes.dart`, `create_notification_test.dart` (6), `notify_triggers_test.dart` (9), `list_my_notifications_test.dart` (10), `mark_notification_read_test.dart` (6) |
| Infrastructure | `postgres_notification_repository.dart` (467 L — `@named` binding only; `createIfAbsent` = `INSERT … ON CONFLICT ON CONSTRAINT notifications_dedupe_uniq DO NOTHING RETURNING id` → `Ok(row.isNotEmpty)`; recipient-scoped `listForRecipient` `ORDER BY created_at DESC, id DESC LIMIT @limit`, `findForRecipient` `WHERE id AND recipient_id`, `markRead` guarded `UPDATE … WHERE id AND recipient_id AND read_at IS NULL RETURNING` + a recipient-scoped existence probe to disambiguate already-read (`Ok(false)`) from foreign/absent (`Ok(null)`), `unreadCount` `WHERE read_at IS NULL`; kind-discriminated subject rebuild; `_reclassify` maps 23505 `notifications_dedupe_uniq` → `notification.duplicate` (create converges to `Ok(false)`) and the four named FKs → recipient/round/group/actor `_not_found`; malformed row → transient `notification.row_corrupt`; total — never throws). Exported from `infrastructure.dart`; `postgres_notification_repository_test.dart` (34, hermetic) + `postgres_notification_repository_integration_test.dart` (DB-gated, tagged `integration`, skipped locally) |
| Migration | `supabase/migrations/0009_notification.sql` (236 L — `notification` schema, `notification.notification_kind` enum with the exact 3 wire tokens, `notification.notifications` table matching the adapter's column list verbatim, four explicitly-named FK constraints `ON DELETE CASCADE`, the `notifications_dedupe_uniq (recipient_id, kind, subject_ref)` idempotency constraint, `notifications_recipient_created_idx` for the newest-first list + partial `notifications_recipient_unread_idx WHERE read_at IS NULL` for the count, recipient self-read RLS `recipient_id = auth.uid()` + client write revocation, anon denied; NO points column, NO free-text/open-graph edge, NO `updated_at`/trigger since only `read_at` mutates; forward-only, re-runnable) |
| Server | `routes/notifications/_middleware.dart` (`bearerAuth` on the whole subtree), `routes/notifications/index.dart` (GET list + separate whole-inbox unread_count / 405; optional `?limit=`, non-integer treated as absent), `routes/notifications/unread_count/index.dart` (GET → `{unread_count}` / 405), `routes/notifications/[id]/read/index.dart` (POST mark → `{read: bool}` / 405); `lib/http/notification_dto_mapper.dart`; CompositionRoot wires all 3 recipient-facing use-cases (`bootstrap` builds one `PostgresNotificationRepository`; `forTesting` `_absent*` + `_UnwiredNotificationRepository`); `test/routes/notifications_routes_test.dart` (458 L) over `InMemoryNotificationRepository` + `storedNotification` in `competition_route_harness.dart` |

---

## 1. Architecture

- **Clean-Architecture dependency rule (ADR 0007) honoured — verified by grep,
  not by claim.** Domain `notification/*` imports only `shared` + domain-internal
  ids (`identity.UserId`, `competition.RoundId`, `group.GroupId`); application
  `notification/*` imports only `application`/`domain`/`shared`; contracts
  `notification_dto.dart` depends on nothing; the Postgres adapter imports only
  `application`/`domain`/`shared`/`postgres` + the internal `db/postgres_connection`.
  No `package:infrastructure` import appears anywhere outside `apps/server`
  (which alone composes the graph). `import_lint` boundaries are intact.
- **No new internal package** — the `notification` slice lives inside the
  existing `domain`/`application`/`contracts`/`infrastructure` packages, so the
  `tooling/import_lint` ruleset is unchanged (§3 confirms this).
- **Command-not-event trigger edge (mirrors the ratified Ledger
  `PostRoundToLedger` decision).** The three creation commands
  (`CreateNotification` + `NotifyRoundScored`/`NotifyGroupMemberJoined`/
  `NotifyReactionReceived`) are synchronous, in-process, idempotent use-cases —
  no unverified async dispatcher this phase. A future outbox can call the
  identical `CreateNotification` unchanged.
- **Tier-3 boundary respected.** Notifications adds NO second points source
  (Axiom 5 — no amount/points column anywhere), NO group ref on any
  Round/Prediction/Leaderboard object (the FK links point FROM notification TO
  competition/group, never the reverse — Axiom 4 / decision #1).

**Verdict: GREEN.**

---

## 2. Security

- **Recipient-only, in TWO layers (decision #4).** Layer 1 (application): every
  read/mark use-case (`ListMyNotifications`, `GetUnreadCount`,
  `MarkNotificationRead`) resolves the recipient as `principal.userId` from the
  verified token via `Authorization.requireRole(principal, PlatformRole.user)`
  — never a body, never a path. Layer 2 (DB backstop): RLS
  `notifications_select_recipient USING (recipient_id = auth.uid())` +
  client write revocation (`revoke insert, update, delete, truncate … from anon,
  authenticated`) + anon-deny. This is a REAL two-layer defence (Security ADR §2
  / DB ADR §10), not a duplicated check: the app gate is primary, RLS is the
  last line if a client ever reached the table directly (it cannot — the
  service role owns writes; the recipient's own mark flows through the backend,
  not a direct client UPDATE).
- **No HTTP creation path (decision #4).** Verified: the `/notifications`
  subtree has exactly three route files — list, unread_count, `[id]/read` — and
  NO create route. Creation is server-triggered only; the three creation
  commands are deliberately NOT wired to any route (a documented decision in
  `bootstrap()`'s comment, not an omission).
- **Recipient always from the token.** `CreateNotification` takes an
  already-resolved `recipientId` from the trigger site (server-resolved: the
  scored round's participant, the group owner, the reacted-to round's
  participant) — never client input. The read/mark use-cases bind
  `principal.userId`. There is no code path where a client names a recipient.
- **No existence oracle.** `MarkNotificationRead` refuses a foreign OR unknown
  id **identically** as `AppError.authorization('notification.not_found', …)` →
  HTTP 401. The adapter's `markRead` returns `Ok(null)` for both a foreign id
  (recipient-scoped WHERE misses) and an absent id, and the existence-probe
  fallback is likewise recipient-scoped — so a caller can never distinguish
  "someone else's notification exists" from "no such id" (mirror of the Ledger
  self-read `participant_not_found`). The route test asserts the foreign case
  and the unknown case produce the SAME `notification.not_found` code.
- **RLS gate correctness.** `recipient_id = auth.uid()` is valid precisely
  because `identity.users.id` IS the Supabase Auth subject UUID (migration
  0001) — a materially simpler, correct gate than the Groups/Social membership
  join, and it needs no `security definer` helper (no added attack surface).
- **No PII / no external channel (decision #2).** In-app-only: no email/phone/
  device-token column, no provider SDK. Nothing to leak, nothing to consent to.
- **Parameter binding.** Every adapter query binds through `@named` parameters
  (no string interpolation of values) — no SQL-injection surface (Security ADR §2).

**Verdict: GREEN.**

---

## 3. Correctness

- **Idempotent creation (decision #3).** `createIfAbsent` is `ON CONFLICT ON
  CONSTRAINT notifications_dedupe_uniq DO NOTHING RETURNING id`: a first insert
  RETURNs a row (`Ok(true)`); a replayed trigger conflicts, RETURNs nothing
  (`Ok(false)`) — never a second row. A concurrent duplicate that slips past
  `ON CONFLICT` surfaces as 23505 → `notification.duplicate`, which
  `_onCreateError` converges to `Ok(false)`. The dedupe key is the deterministic
  `NotificationSubject.dedupeRef` (`round:<id>` etc.), so the SAME event dedupes
  and a DISTINCT event does not — re-scoring a round, or a reactor re-reacting,
  never double-notifies.
- **Idempotent mark-read (decision #3), correctly disambiguated.** The domain
  `Notification.markRead` returns `this` (preserving the original `readAt`) when
  already read. The adapter's guarded `UPDATE … WHERE … read_at IS NULL
  RETURNING` transitions an unread row (`Ok(true)`); when it updates nothing, a
  recipient-scoped existence probe distinguishes an already-read owned row
  (`Ok(false)`, idempotent) from a foreign/absent id (`Ok(null)`, → not_found).
  The route test asserts the already-read case is `200 read:false` AND that the
  original timestamp is untouched.
- **Self-reaction suppression.** `NotifyReactionReceived` guards
  `recipientId == actorUserId` → silent `Ok(false)` — a member reacting to their
  own round-result never self-notifies (decision #1). The application test
  covers this.
- **Owner-only member-joined.** `NotifyGroupMemberJoined` addresses the group
  `ownerId` (no N² fan-out — decision #1); the trigger site passes it only on a
  genuinely new join (documented contract), so a re-confirmed membership does
  not re-notify.
- **Subject/kind consistency.** `Notification.create` rejects a
  `subject.kind != kind` mismatch (`notification.subject_kind_mismatch`) — a
  caller bug is a typed validation error, never persisted. The adapter rebuilds
  the subject per the stored `kind` discriminant, and a required reference that
  is absent/malformed is a corrupt-row transient (never a silently wrong subject).
- **UTC discipline.** `createdAt`/`readAt` are UTC-gated in the domain and
  `.toUtc()`-normalized on both write (adapter binding) and read (row mapping),
  so newest-first ordering is unambiguous.
- **Limit clamp.** `ListMyNotifications` clamps an untrusted `limit` to
  `[1, maxLimit=200]`, null/non-positive → `defaultLimit=50`; the route treats a
  non-integer `?limit=` as absent (`int.tryParse` → null). The route test proves
  in-range / over-cap / non-integer / missing all reach the repository at the
  clamped value.

**Verdict: GREEN.**

---

## 4. Performance

- **Both hot recipient reads are index-backed by `0009_notification.sql`:**
  - the newest-first list (`WHERE recipient_id = ? ORDER BY created_at DESC,
    id DESC LIMIT ?`) is served by `notifications_recipient_created_idx
    (recipient_id, created_at desc, id desc)` — the index direction matches the
    ORDER BY exactly, so it is an index-ordered scan with an early LIMIT cut,
    no sort node.
  - the unread count (`WHERE recipient_id = ? AND read_at IS NULL`) is served by
    the **partial** index `notifications_recipient_unread_idx (recipient_id)
    WHERE read_at IS NULL` — read rows are excluded from the index, so the count
    probe stays tiny even for a user with a large read history.
- **The dedupe/conflict probe** rides the unique `notifications_dedupe_uniq
  (recipient_id, kind, subject_ref)` — the `ON CONFLICT` target is index-backed.
- **`?limit=` is hard-capped** at 200 (`maxLimit`), so a single list read can
  never ask for an unbounded scan (Tier-3 read stays cheap — decision #4).
- The `markRead` two-query path (guarded UPDATE + a recipient-scoped existence
  probe on the no-op branch) is bounded (PK/recipient equality lookups) and only
  the no-op branch pays the second query — an acceptable, localized cost for the
  clean idempotent/foreign disambiguation without an existence oracle.

**Verdict: GREEN.** (No High/Medium; the two-query mark-read is an intentional,
bounded trade-off, recorded as info-only P-note.)

---

## 5. Maintainability

- **Comments match the four ratified decisions** consistently across domain,
  application, adapter, migration, routes, and mapper — every "decision #N"
  reference in the code corresponds to the §2 ratified block.
- **No logic duplicated across layers.** The recipient-only gate is stated once
  per use-case (application) and once as the RLS backstop (migration); the
  wire-shaping lives once in `notification_dto_mapper.dart`; the single idempotent
  create path (`CreateNotification`) is what all three trigger commands delegate
  to — the trigger sites depend on one thing.
- **Constraint names are the adapter/migration contract**, and the migration's
  header comment explicitly says they MUST NOT be renamed without updating the
  adapter in lockstep — the coupling is documented at the seam.
- **Mirrors the closest analog (Social) file-for-file** — same adapter test
  style (hermetic fake connection + DB-gated integration peer), same harness
  in-memory-repo pattern, same route-test structure — so a future maintainer
  reads one pattern across phases.

**Verdict: GREEN.**

---

## 6. Production-readiness

- **The real `PostgresNotificationRepository` is wired in production
  (`bootstrap`), NOT an unwired stub — verified at the call site.** `bootstrap()`
  builds `final notificationRepository = PostgresNotificationRepository(connection)`
  and passes all three `required` use-cases to `CompositionRoot._(...)`:
  `listMyNotifications: ListMyNotifications(notifications: notificationRepository)`,
  `getUnreadCount: GetUnreadCount(notifications: notificationRepository)`,
  `markNotificationRead: MarkNotificationRead(notifications: notificationRepository,
  clock: clock)`. The `_UnwiredNotificationRepository` (every method throws
  `StateError`) backs ONLY the `forTesting` `_absent*` stand-ins, never the
  production graph.
- **The session-42 compile break is FIXED and confirmed.** The three params on
  the private constructor (`required this.listMyNotifications` /
  `getUnreadCount` / `markNotificationRead`, lines 48-50) are all backed by
  fields (lines 520/524/530), `forTesting` supplies matching optional params +
  `_absent*` defaults (lines 110-112, 154-158), and the `bootstrap()`
  `CompositionRoot._(...)` call site passes all three (lines 762-771). The
  use-case constructor signatures match the passed args verbatim
  (`notifications:` on all three, `clock:` on `MarkNotificationRead`). No other
  call site of `CompositionRoot._` or `.forTesting` is broken.
- **No TODO / placeholder / mock in shipped code** — verified by inspection of
  every file; the only "in-memory" / "fake" artifacts are in `test/`.
- **Total adapter (Application ADR §2)** — never throws; a driver failure is
  `ErrorKind.transient`, a malformed row is `notification.row_corrupt`
  (transient), SQLSTATE 23505/23503 map to typed errors by explicitly-named
  constraint.
- **Tests at every layer** — domain (4 files), contracts (1), application (5,
  incl. the 3 trigger commands + recipient reads), infrastructure (34-case
  hermetic + DB-gated integration), server (458-line route test). Every route
  error path (503 / 405 / 400 / 401-foreign / 401-unknown-no-oracle) has a test.
- **Migration is forward-only, expand-only, re-runnable** (`create … if not
  exists`, `drop policy if exists`), matching the migration discipline of
  0001–0008.

**Environment note (unchanged, §2):** the sandbox has no Dart/Flutter
toolchain, so verification is by-construction + version-checking; "compiles &
goes green" is to be confirmed via `melos bootstrap && melos run verify` on a
Dart-3.12+ machine, and the DB-gated integration test in CI's integration job
against an ephemeral Postgres with migrations 0001–0009 applied.

**Verdict: GREEN.**

---

## 7. Summary of findings

| # | Severity | Area | Finding | Resolution |
|---|---|---|---|---|
| N-1 | Verified-OK | Production | `bootstrap()` wires the real `PostgresNotificationRepository` into all three use-cases at the `CompositionRoot._(...)` call site; the session-42 compile break is fixed and confirmed (fields + `forTesting` defaults + call-site args all consistent; signatures match verbatim). | None — correct on disk. |
| N-2 | Verified-OK | Security | Recipient-only in two layers (app gate + RLS backstop); foreign & unknown ids refused identically (`notification.not_found`) with no existence oracle; no HTTP creation path; recipient always from the token. | None — correct on disk. |
| N-3 | Verified-OK | Correctness | Idempotent create (`ON CONFLICT DO NOTHING` + 23505 convergence) and idempotent mark-read (guarded UPDATE + recipient-scoped existence probe), both proven by tests incl. original-timestamp preservation; self-reaction suppressed; owner-only member-joined. | None — correct on disk. |
| P-note | Info (Low) | Performance | `markRead`'s no-op branch pays a second recipient-scoped existence query to disambiguate already-read from foreign/absent without an oracle. Bounded (equality lookups), only on the no-op branch. | Intentional trade-off; deferred, no change. |
| S-verified | Info | Security | RLS `recipient_id = auth.uid()` is correct because `identity.users.id` is the Supabase Auth subject UUID (0001). | None. |
| M-note | Info | Maintainability | Constraint names couple adapter ↔ migration; documented at the seam in the migration header. | None. |

**No High or Medium defect. No code change was required this session** — every
layer was verified already-correct by direct on-disk inspection; the previously
recorded session-42 compile break was confirmed already-fixed and correct.

---

## 8. Exit criterion

Notifications delivered end-to-end at full Milestone-0 rigor across all six
layers (domain → contracts → application → infrastructure → migration
`0009_notification.sql` → `apps/server` routes + mapper + CompositionRoot
wiring + route tests). The four ratified decisions are honoured physically:
in-app-only stored per-user mutable read-state (decision #2/#3), a bounded
closed 3-kind trigger surface with server-only idempotent creation
(decision #1), strictly recipient-only visibility with no existence oracle and
a two-layer (app + RLS) defence (decision #4). Axioms 2/4/5/6 honoured
(server-only writes, no group ref on any core object, no second points source,
DB as last line of defence). No new external dependency; `import_lint` ruleset
unchanged. Six-way review **GREEN**. Exit criterion **MET** — **Notifications
phase COMPLETE & RATIFIED.** Next phase: **Admin Panel** (Roadmap ADR 0008
phase 11).
