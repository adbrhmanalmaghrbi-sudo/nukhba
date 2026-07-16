# Admin Panel Phase — Six-Way Review

_Phase-exit review, 2026-07-13, auditor role — by DIRECT on-disk inspection of
every Admin Panel file across all six layers plus the `apps/server` wiring, the
migration, and the four route tests (NOT trusting the §4 checklist). Result:
**GREEN**. No High or Medium defect remains open. Two code-level findings were
made against earlier state and are both RESOLVED: **DEFECT AD-1** (a real
production compile break in `bootstrap()`) was fixed in the prior session and is
re-confirmed correct at the call site here; **AD-2** (a genuinely-misleading
dartdoc error code in two admin route files) was found AND fixed in THIS review
session (not merely documented). Admin Panel is the 11th phase (Roadmap ADR
0008), immediately after Notifications; the next phase is Flutter App (phase
12)._

The five product/architecture decisions (project-context §2 **Milestone (Admin
Panel) — Decisions Ratified** + §4 **RATIFIED / OPEN-A / OPEN-B**) are the fixed
premises of this review and are NOT re-litigated:
1. Reuse existing ratified use-cases under an admin-elevated caller; a NEW
   use-case is authored ONLY where no ratified equivalent exists (the user
   sanction + the audited support read).
2. "admin" is the EXISTING `PlatformRole.admin` on the shipped identity/JWT
   model + `Authorization.requireRole` — NO separate authentication path.
3. Delivery surface this phase = BACKEND ROUTES ONLY (`apps/server`); no admin
   UI (deferred to Flutter phase 12).
4. **[OPEN-A]** user-sanction/moderation scope = a reversible `suspend`/
   `reinstate` pair carrying a mandatory reason; NO Group/Social moderation in
   v1; a narrow, read-only, itself-audited cross-user ledger read for support.
5. **[OPEN-B]** audit = ONE general append-only `admin.audit_log` table (its own
   migration `0010_admin.sql`), covering ALL admin actions, append-only only
   (RLS deny-all + privilege revocation + immutability trigger; no crypto
   signing in v1).

---

## 0. Scope verified on disk

| Layer | Files (verified present & complete — no shipped TODO / placeholder / mock; grep across all admin lib code returned NONE) |
|---|---|
| Domain | `admin/audit_entry_id.dart` (UUID-validated `EntityId`, `tryParse`; distinct type from `UserId`/`RoundId`/`GroupId`/`NotificationId`/`ReactionId`), `admin/audit_action.dart` (`AuditAction` closed 11-set with stable `wireValue` + total `tryParse` → `admin.audit_action_unknown`), `admin/audit_entry.dart` (`AuditEntry`: `create`/`fromStored`; **NO mutation API at all** — append-only by construction; UTC-gated `occurredAt` `admin.audit_occurred_at_not_utc`; non-blank `targetRef` `admin.audit_target_ref_empty`; supplied-reason non-blank + `maxReasonLength=500` `admin.audit_reason_empty`/`_too_long`; opaque `targetRef` = provenance not FK; NO points field — Axiom 5). Plus the amendment `identity/user.dart` `suspend()`/`reinstate()` (idempotent both directions; `suspend()` refuses a `service` principal `identity.cannot_suspend_service`; pure, produces a new value via `copyWith`). All 3 admin ids/values exported from `domain.dart`; tests `audit_entry_id_test.dart`, `audit_action_test.dart`, `audit_entry_test.dart` + the 9 suspend/reinstate cases in `identity/identity_test.dart` |
| Contracts | `admin_dto.dart` (`SuspendUserRequestDto` — the ONLY client-supplied admin command body, mandatory `reason` nullable-on-wire-only so a missing field is a use-case validation failure, reused verbatim by suspend+reinstate; `UserSanctionResultDto` user_id + `status` matching `UserStatus.name`; `AuditEntryDto` read projection, `action` as stable wire token, `reason` **omitted from JSON when null**; `AuditLogDto` newest-first entries, empty legitimate; all versioned, snake_case, NO points field — Axiom 5, no target/actor in a command body). Exported from `contracts.dart`; `admin_dto_test.dart` (181 L) |
| Application | ports `admin/ports/user_admin_repository.dart` (`UserAdminRepository`: `findUserById` → `Ok(null)` absent, `updateUser` status-only — a new narrow port justified exactly like Ledger's `ParticipantReader`, the frozen `UserDirectory` not widened) + `admin/ports/audit_log_repository.dart` (`AuditLogRepository`: `append`, `list` — deliberately NO update/delete: append-only at the port); `admin/audit_recorder.dart` (`AuditRecorder` — the SINGLE audit-write path, server-side, generates id + stamps UTC clock + `AuditEntry.create` + `append`; propagates the error, NOT best-effort); `admin/suspend_user.dart` (`SuspendUser` + `ReinstateUser`; admin gate → mandatory reason → resolve → pure transition → persist → audit); `admin/list_audit_log.dart` (`ListAuditLog`; admin gate + clamp `[1,200]`, default 50); `admin/view_participant_ledger.dart` (`ViewParticipantLedger`; admin gate → resolve → **audit BEFORE serve** → return stream). All 6 symbols exported from `application.dart`; tests `fakes.dart` (244 L), `suspend_user_test.dart` (226 L, 15 cases incl. blank/null reason + service refusal), `list_audit_log_test.dart` (141 L, 10 cases), `view_participant_ledger_test.dart` (209 L, 9 cases incl. **FAIL-CLOSED**) |
| Infrastructure | `admin/postgres_user_admin_repository.dart` (`@named` binding only; `findUserById` `SELECT id,email,role,status WHERE id=@id` → row map / `Ok(null)`; `updateUser` **status-only** `UPDATE … SET status=@status, updated_at=now() WHERE id=@id RETURNING …` — never writes role/email; empty RETURNING → transient `identity.update_no_row`; malformed row → transient `identity.row_corrupt`; 23514 → `identity.status_invalid`; total, never throws) + `admin/postgres_audit_log_repository.dart` (`append` plain `INSERT … RETURNING id` — no ON CONFLICT, a duplicate server-generated id is a defensive backstop; `list` `ORDER BY occurred_at DESC, id DESC LIMIT @limit`; `_reclassify` maps 23505 `audit_log_pkey` → `admin.audit_duplicate` + 23503 `audit_log_actor_id_fkey` → `admin.audit_actor_not_found`; malformed row → transient `admin.audit_row_corrupt`; total). Both exported from `infrastructure.dart`; `postgres_admin_repositories_test.dart` (357 L, hermetic) + `postgres_admin_repositories_integration_test.dart` (110 L, DB-gated, tagged `integration`, skipped locally) |
| Migration | `supabase/migrations/0010_admin.sql` (256 L — `admin` schema, `admin.audit_action` enum whose 11 values match `AuditAction.wireValue` **one-to-one** (verified by diff), `admin.audit_log` table matching the adapter's column list verbatim, PK `audit_log_pkey` + explicitly-named FK `audit_log_actor_id_fkey` `ON DELETE RESTRICT` (the trail never loses its actor) + two check constraints (`reason` non-blank when present, `target_ref` non-blank), `audit_log_occurred_idx (occurred_at desc, id desc)` matching the list ORDER BY, `admin.reject_audit_mutation()` immutability trigger on `before update or delete` for EVERY role incl. service (mirrors `ledger.reject_entry_mutation`), RLS **deny-all** to anon+authenticated + full privilege REVOKE + an explicit `USING (false)` select policy; NO points column, NO `updated_at`/set_updated_at trigger since the row is immutable; forward-only, re-runnable) |
| Server | `routes/admin/_middleware.dart` (`bearerAuth` on the whole subtree; authz inside the use-cases), `routes/admin/users/[id]/suspend/index.dart` (POST → `UserSanctionResultDto` / 405), `routes/admin/users/[id]/reinstate/index.dart` (POST / 405), `routes/admin/participants/[id]/ledger/index.dart` (GET, optional `?reason=` / 405), `routes/admin/audit/index.dart` (GET, optional `?limit=` non-integer-treated-as-absent / 405); `lib/http/admin_dto_mapper.dart` (single-place shaping); CompositionRoot wires all 4 admin use-cases (`bootstrap` builds one `PostgresUserAdminRepository` + one `PostgresAuditLogRepository` + one shared `AuditRecorder`; `forTesting` `_absent*` + `_Unwired*` throwing repos + throwing `AuditRecorder`); `test/routes/admin_routes_test.dart` (687 L) over `InMemoryUserAdminRepository` + `InMemoryAuditLogRepository` + `adminPrincipal()`/`userPrincipal()`/`storedUser()`/`storedAuditEntry()` in `competition_route_harness.dart` |

**Route ↔ test coverage cross-check (the mandatory §4 point — every route/status
compared against the test, not assumed).** The `apps/server/routes/admin/`
subtree has exactly four handlers; each status code each emits is covered:

| Route | Emitted statuses | Covered by `admin_routes_test.dart` |
|---|---|---|
| `POST /admin/users/{id}/suspend` | 200, 400 (`admin.sanction_reason_required`), 401 (`auth.insufficient_role`), 409 (`admin.user_not_found`), 405 | 200 + persisted status + 1 attributed audit + no `points` key; idempotent re-suspend (still 1 audit); 401 (no write, no audit); 400 missing reason (pre-write); 400 blank reason (pre-write); 409 unknown user (no audit); 405 |
| `POST /admin/users/{id}/reinstate` | 200, 400, 401, 409, 405 | 200 → active + 1 audit `user_reinstated`; idempotent already-active; 401 (untouched, no audit); 400 missing reason; 405 |
| `GET /admin/participants/{id}/ledger` | 200, 400 (malformed id), 401, 409 (`admin.participant_not_found`), 503 (fail-closed), 405 | 200 + 1 `participant_ledger_viewed` carrying `?reason=`; empty ledger still 200 + still audited (null reason); 401 (no read, no audit); 409 no-oracle no-audit; 400 malformed; **fail-closed 503 with zero rows on the trail**; 405 |
| `GET /admin/audit` | 200, 401, 503 (transient), 405 | 200 newest-first (no `points` key); empty trail 200; 401 even with rows present; `?limit=` in-range/over-cap(→maxLimit)/non-integer(→default)/missing(→default) asserted via `lastRequestedLimit`; 503 transient; 405 |

**No gap found** between the live route list and the test coverage — every route
and every status each route can return has an asserting test.

---

## 1. Architecture

- **Clean-Architecture dependency rule (ADR 0007) honoured — verified by grep,
  not by claim.** Domain `admin/*` imports only `shared` + domain-internal ids
  (`identity.UserId`); the `suspend()`/`reinstate()` amendment lives on the
  existing `User` entity and imports nothing new. Application `admin/*` imports
  only `application`/`domain`/`shared` (the support read reuses the Ledger
  slice's `ParticipantReader` + `LedgerRepository` ports — no cross-context
  internal reach). Contracts `admin_dto.dart` depends on nothing. The two
  Postgres adapters import only `application`/`domain`/`shared`/`postgres` + the
  internal `db/postgres_connection`. No `package:infrastructure` import appears
  outside `apps/server`. `import_lint` boundaries are intact.
- **No new internal package** — the `admin` slice lives inside the existing
  `domain`/`application`/`contracts`/`infrastructure` packages, so the
  `tooling/import_lint` ruleset is unchanged.
- **Reuse over duplication (decision #1) is real, not nominal.** The ONE
  genuinely-new capability (the user sanction) got a new domain hook
  (`suspend()`/`reinstate()`) + a new narrow port (`UserAdminRepository`) + new
  use-cases — because `UserStatus.suspended` had a hook but no transition
  use-case, and the frozen `UserDirectory` has no by-id/find-or-update-another
  capability. The cross-user support read got a new use-case
  (`ViewParticipantLedger`) precisely because its gate DIFFERS from the frozen
  `ReadParticipantLedger` (admin-reads-someone-else vs self-read) — it does NOT
  duplicate it, it reuses the same ledger ports under a different, audited gate.
  Every crown-jewel/authoring admin command (competition/scoring/ledger) is a
  REUSED use-case under an admin-elevated caller (the `AuditAction` enum records
  those verbs for one consistent trail) — not a parallel "admin" copy that would
  violate the single-writer rule.
- **The audit log is peripheral (Axiom 5).** The FK points FROM the audit row TO
  `identity.users` (actor); `target_ref` is an OPAQUE provenance string, never a
  FK onto a core aggregate — nothing in competition/scoring/ledger references the
  audit log back. It only OBSERVES; it is never a second source of truth.

**Verdict: GREEN.**

---

## 2. Security

- **Admin authority in TWO layers, the FIRST inside every use-case (decision #2;
  Security ADR §2.3).** Layer 1 (application): `SuspendUser`/`ReinstateUser`/
  `ListAuditLog`/`ViewParticipantLedger` EACH call
  `Authorization.requireRole(principal, PlatformRole.admin)` as the very first
  step (verified in-file for all four use-cases, not by the test alone — the
  §4-mandatory point). A non-admin is refused `auth.insufficient_role` (→ 401)
  BEFORE any repository is consulted and BEFORE any audit is written (the tests
  assert "no write, no audit" on the rejected path for all four). Layer 2 (DB
  backstop): the `admin.audit_log` RLS is **deny-all** to every client role
  (no permissive policy of any kind + full privilege REVOKE + an explicit
  `USING (false)` select policy) — no client, not even an authenticated one,
  ever reads the trail; the admin read flows through the RLS-bypassing service
  role gated by `ListAuditLog`. `PlatformRole.admin` is the ONLY authorization
  model; the middleware only establishes WHO the caller is (authentication), and
  there is no separate admin auth path (decision #2). *(Operational admin MFA is
  an identity-provider configuration concern per Security ADR §6 "Deferred to
  Implementation," not a code surface this phase owns — correctly out of scope.)*
- **Every admin action is audited, and the audit write is FAIL-CLOSED for the
  crown-jewel read (the §4-mandatory point — verified in the code for all three
  use-cases, not just the test).**
  - `ViewParticipantLedger` records the `participant_ledger_viewed` entry
    **BEFORE** returning the ledger data (in-file: the `_audit.record(...)` call
    and its `if (audit is Err) return Result.err(...)` guard precede the
    `_ledger.listEntries(...)` return). A failed audit append therefore REFUSES
    the read — cross-user data is never served un-traced. The application test
    (`view_participant_ledger_test.dart`, the `FAIL-CLOSED` case) and the route
    test (`admin_routes_test.dart`, the 503-with-zero-rows case) both prove it.
  - `SuspendUser`/`ReinstateUser` record the sanction audit AFTER a successful
    persist, and a failed audit write PROPAGATES the error (in-file: the
    `if (audit is Err) return Result.err(...)` after `updateUser`). The write is
    NOT best-effort (unlike Notifications' Tier-3 degradation) — a sanction
    cannot complete-and-report-success without its attributable trace. (See M-1
    below for the one honest nuance: the *persist* precedes the audit, so a
    sanction can take effect and still return an error if the trail write fails;
    this is the safe direction for an append-only accountability record and is
    documented, not a defect.)
- **The append-only guarantee is layered against even a compromised backend
  (the §4-mandatory point — verified the migration's constraint names match the
  adapter).** The port has no update/delete; the app only calls `append`; the
  migration REVOKEs UPDATE/DELETE/TRUNCATE from every client role AND installs
  `admin.reject_audit_mutation()` as a `before update or delete` trigger that
  raises for EVERY role INCLUDING the RLS-bypassing service role (Axiom 5/6,
  mirroring `ledger.reject_entry_mutation`). The adapter's SQLSTATE→typed map
  keys off the EXACT constraint names the migration declares — verified in
  lockstep: `audit_log_pkey` (default PK name → `admin.audit_duplicate`) and
  `audit_log_actor_id_fkey` (explicitly named → `admin.audit_actor_not_found`)
  both appear verbatim in `0010_admin.sql`.
- **No existence oracle.** An unknown target user is `admin.user_not_found`
  (409); an unknown participant is `admin.participant_not_found` (409) with no
  audit trace (nothing was read) — a missing subject is never distinguished from
  a well-formed-but-absent one beyond the typed not-found.
- **The actor is always server-bound.** Every audit `actorId` and every
  authorization decision is `principal.userId` from the verified token; the
  target user/participant id is the path capability; the ONLY client-supplied
  value in the entire surface is the sanction `reason` (and the optional support
  `?reason=`). No request body ever names an actor or a recipient.
- **Status-only mutation.** `PostgresUserAdminRepository.updateUser` writes ONLY
  the `status` column (verified: the UPDATE sets `status` + `updated_at`, never
  `role`/`email`) — an admin cannot ride a role elevation in on a suspend.
- **Parameter binding.** Every adapter query binds through `@named` parameters
  (no value interpolation) — no SQL-injection surface (Security ADR §2).

**Verdict: GREEN.**

---

## 3. Correctness

- **Idempotent sanction (decision OPEN-A #1).** `User.suspend()` returns an equal
  value when already suspended (and `reinstate()` when already active) — the
  domain transition converges, so a repeated sanction is a 200 echoing the same
  status without error. The route test proves re-suspend → still `suspended` +
  still exactly one audit row per action; the domain `identity_test.dart` proves
  the idempotency and immutability directly (9 cases).
- **Service principal cannot be suspended.** `suspend()` refuses a `service`
  principal `identity.cannot_suspend_service` (an `invariant`), and the check
  precedes the idempotency short-circuit even when already suspended (asserted in
  `identity_test.dart`). `reinstate()` deliberately does NOT gate on role (a
  suspended admin can be reinstated).
- **Mandatory reason, pre-write (decision OPEN-A #1).** `SuspendUser._requireReason`
  rejects a missing/blank reason `admin.sanction_reason_required` BEFORE parsing
  the id, resolving the user, or writing anything — the route tests assert the
  user stays `active` and the trail stays empty for both a missing and a blank
  reason.
- **Audit-before-serve for the support read (decision OPEN-A #3).** Covered
  under §2; the empty-ledger case still records exactly one audit entry (the read
  is audited regardless of whether the stream has movements) — asserted.
- **Wire-token discipline.** `AuditAction` crosses the wire as its stable
  `wireValue` token (never a Dart enum name), the mapper emits it, and the
  migration enum tokens match one-to-one (diff verified) — a persisted action can
  never drift. `AuditAction.tryParse` makes an unknown stored token a corrupt-row
  transient, not a silent coercion.
- **Reason nullability is consistent end-to-end.** `AuditEntry.create` allows a
  null reason (for a support read) but rejects a supplied-but-blank one; the DTO
  omits the `reason` key when null; the adapter binds `null` and maps a stored
  null back; the migration's check permits null-or-non-blank. A sanction's reason
  is mandatory at the USE-CASE, not the domain constructor — verified at the
  use-case level, exactly as the §4 note requires.
- **UTC discipline.** `occurredAt` is UTC-gated in `AuditEntry.create`,
  `.toUtc()`-normalized on adapter write and read, and emitted ISO-8601 UTC by
  the mapper — newest-first ordering is unambiguous.
- **Limit clamp.** `ListAuditLog` clamps `[1, maxLimit=200]`, null/non-positive
  → `defaultLimit=50`; the route treats a non-integer `?limit=` as absent
  (`int.tryParse` → null). The route test proves all four cases reach the
  repository at the clamped value via `lastRequestedLimit`.

**Verdict: GREEN.**

---

## 4. Performance

- **The single hot audit read is index-backed by `0010_admin.sql`:** the
  newest-first trail (`ORDER BY occurred_at DESC, id DESC LIMIT @limit`) is
  served by `audit_log_occurred_idx (occurred_at desc, id desc)` — the index
  direction matches the ORDER BY exactly, so it is an index-ordered scan with an
  early LIMIT cut, no sort node.
- **`?limit=` is hard-capped** at 200 (`ListAuditLog.maxLimit`) so a single
  audit read can never ask for an unbounded scan.
- **The sanction/support-read paths are equality lookups** — `findUserById` /
  `findParticipantById` on PK, the status UPDATE on PK, the audit INSERT is a
  single append. No scan, no N+1.
- **The support read reuses the frozen ledger stream read** (`listEntries` on the
  participant-stream index already shipped in `0005_ledger.sql`) — no new query
  shape, no new index needed.

**Verdict: GREEN.**

---

## 5. Maintainability

- **Comments match the five ratified decisions** consistently across domain,
  application, adapters, migration, routes, and mapper — every "decision
  OPEN-A/OPEN-B/§2 #N" reference in the code corresponds to a ratified block.
- **No logic duplicated across layers.** The admin gate is stated once per
  use-case; the single audit-write path (`AuditRecorder`) is what every audited
  use-case delegates to; the wire-shaping lives once in `admin_dto_mapper.dart`;
  the support read reuses the ledger ports rather than re-deriving a stream read.
- **Constraint names are the adapter/migration contract**, and the migration's
  header comment explicitly says `audit_log_pkey`/`audit_log_actor_id_fkey` MUST
  NOT be renamed without updating the adapter in lockstep — the coupling is
  documented at the seam and verified matching here.
- **Mirrors the closest analogs (Notifications/Ledger) file-for-file** — same
  adapter test style (hermetic fake connection + DB-gated integration peer), same
  harness in-memory-repo pattern, same route-test structure, the immutability
  trigger mirrors `ledger.reject_entry_mutation`, the append-only port mirrors
  the ledger port — one pattern reads across phases.
- **AD-2 (found + fixed this session — a real maintainability defect, not a
  guess):** the dartdoc in `routes/admin/audit/index.dart` and
  `routes/admin/_middleware.dart` described the non-admin refusal as
  `401 identity.forbidden_role`, but the code `Authorization.requireRole`
  actually returns `auth.insufficient_role` (grep confirmed `forbidden_role`
  existed ONLY in those two comments; the sole authoritative code is
  `auth.insufficient_role` in `authorization.dart`, and all four route/use-case
  tests assert `auth.insufficient_role`). A future maintainer reading the doc
  would have chased a non-existent error code. **Fixed in-place** in both files
  to `auth.insufficient_role` — behaviour was already correct; only the
  misleading comment changed.

**Verdict: GREEN.**

---

## 6. Production-readiness

- **The real adapters are wired in production (`bootstrap`), NOT unwired stubs —
  verified at the call site.** `bootstrap()` builds
  `final userAdminRepository = PostgresUserAdminRepository(connection)`,
  `final auditLogRepository = PostgresAuditLogRepository(connection)`, and a
  single shared `final auditRecorder = AuditRecorder(auditLog: auditLogRepository,
  idGenerator: idGenerator, clock: clock)` (reusing the already-in-scope
  `idGenerator`/`clock`), then passes all four `required` use-cases to
  `CompositionRoot._(...)`: `suspendUser: SuspendUser(users:, auditRecorder:)`,
  `reinstateUser: ReinstateUser(users:, auditRecorder:)`,
  `listAuditLog: ListAuditLog(auditLog:)`, `viewParticipantLedger:
  ViewParticipantLedger(participantReader:, ledgerRepository:, auditRecorder:)`
  (the last two reusing the Ledger slice's already-built `participantReader` +
  `ledgerRepository`). The `_Unwired*` throwing repos + throwing `AuditRecorder`
  back ONLY the `forTesting` `_absent*` stand-ins, never the production graph.
- **DEFECT AD-1 (High — the production compile break) is FIXED and re-confirmed.**
  The private `CompositionRoot._({...})` marks the four admin use-cases
  `required` (lines 117-120 as fields at 589-602); an earlier `bootstrap()` never
  built the admin repositories nor passed the four args, so the production
  build did not compile (only `forTesting`, whose params are optional, did — a
  route test could pass while the server could not be built). The prior session
  added the admin slice to `bootstrap()` (verified above); this review confirms
  every `required` arg is now supplied and the ctor param NAMES match the
  use-case constructors verbatim (`users:`/`auditRecorder:`/`auditLog:`/
  `participantReader:`/`ledgerRepository:`). No other `CompositionRoot._` /
  `.forTesting` call site is broken. The compile break is closed; no further
  code change was required for AD-1 in this review.
- **No TODO / placeholder / mock in shipped code** — verified by grep across all
  admin `lib`/route/mapper files (returned NONE); the only "in-memory"/"fake"
  artifacts are in `test/`.
- **Total adapters (Application ADR §2)** — neither throws; a driver failure is
  `ErrorKind.transient`, a malformed row is `admin.audit_row_corrupt` /
  `identity.row_corrupt` (transient), and SQLSTATE 23505/23503/23514 map to typed
  errors by explicitly-named constraint / code.
- **Tests at every layer** — domain (3 admin files + 9 suspend/reinstate cases in
  `identity_test.dart`), contracts (1, 181 L), application (3 use-case files: 15
  + 10 + 9 cases, over `fakes.dart`), infrastructure (357-L hermetic + 110-L
  DB-gated integration), server (687-L route test). Every route error path
  (503 / 405 / 400 / 401 / 409 / fail-closed) has an asserting test.
- **Migration is forward-only, expand-only, re-runnable** (`create schema/type/
  table if not exists`, `create or replace function`, `drop trigger/policy if
  exists`), matching the discipline of 0001–0009. The append-only row has no
  `updated_at`/trigger by design.

**Environment note (unchanged, §2):** the sandbox has no Dart/Flutter toolchain,
so verification is by-construction + version-checking; "compiles & goes green" is
to be confirmed via `melos bootstrap && melos run verify` on a Dart-3.12+
machine, and the DB-gated integration test in CI's integration job against an
ephemeral Postgres with migrations 0001–0010 applied.

**Verdict: GREEN.**

---

## 7. Summary of findings

| # | Severity | Area | Finding | Resolution |
|---|---|---|---|---|
| AD-1 | High (RESOLVED prior session, re-confirmed) | Production | `bootstrap()` had marked the four admin use-cases `required` but never built the admin repositories/`AuditRecorder` nor passed the four args → the production build did not compile (only `forTesting` did). | Fixed in the prior session (admin slice added to `bootstrap`); re-confirmed correct at the `CompositionRoot._(...)` call site here — every `required` arg supplied, ctor names match verbatim. No change needed this review. |
| AD-2 | Low (RESOLVED this session — real, code-adjacent) | Maintainability | `routes/admin/audit/index.dart` + `routes/admin/_middleware.dart` dartdoc named the non-admin refusal `401 identity.forbidden_role`, but the code returns `auth.insufficient_role` (grep: `forbidden_role` existed only in those two comments; all tests assert `auth.insufficient_role`). | **Fixed in-place** in both files to `auth.insufficient_role`. Behaviour was already correct; only the misleading comment changed. |
| AD-3 | Verified-OK | Security | Every admin use-case gates `Authorization.requireRole(PlatformRole.admin)` FIRST (before any repo/audit), verified in-file for all four; a non-admin path writes nothing and audits nothing. `PlatformRole.admin` is the only authz model, no separate auth path. | None — correct on disk. |
| AD-4 | Verified-OK | Security/Correctness | The audit trail is append-only in three layers (port has no update/delete; client privileges revoked; `admin.reject_audit_mutation` trigger rejects UPDATE/DELETE for every role incl. service); adapter constraint names match `0010_admin.sql` verbatim (`audit_log_pkey`/`audit_log_actor_id_fkey`). | None — correct on disk. |
| AD-5 | Verified-OK | Security | Cross-user support read audits BEFORE serving and is FAIL-CLOSED (a failed audit append → 503, zero rows served/logged) — proven by both the application and route tests; sanction audits are propagated, not best-effort. | None — correct on disk. |
| M-1 | Info (Low) | Correctness | For `SuspendUser`/`ReinstateUser` the status *persist* precedes the audit write, so a sanction can take effect and still return an error if the trail write fails (the reverse of the support read's audit-first order). This is the safe direction for an append-only accountability record (never a silent un-persisted "success"), and the operation is idempotent so a retry converges. | Intentional; documented in the use-case. Deferred, no change. |
| S-verified | Info | Security | The `admin.audit_log` RLS deny-all is correct because the trail is never a client-readable surface (unlike notifications' recipient self-read) — the admin read flows through the service role gated by `ListAuditLog`. | None. |
| P-note | Info | Performance | The newest-first audit read is index-ordered (`audit_log_occurred_idx` matches the ORDER BY) with a hard `maxLimit=200` cap; all other admin paths are PK/equality lookups. | None. |
| M-note | Info | Maintainability | Constraint names couple adapter ↔ migration; documented at the seam in the migration header. | None. |

**No High or Medium defect remains open.** AD-1 (High) was resolved before this
review and re-confirmed; AD-2 (Low) was found AND fixed in this review session.
All remaining findings are info/verified-OK.

---

## 8. Exit criterion

**MET.** The Admin Panel surface is delivered end-to-end at full Milestone-0
rigor across all six layers (domain sanction hook + append-only audit aggregate →
contracts → application use-cases + the single `AuditRecorder` write path →
Postgres adapters → migration `0010_admin.sql` → `apps/server` routes + route
tests), reviewed six ways with a GREEN verdict. The five ratified decisions are
honoured PHYSICALLY and verified against the code (not assumed): admin authority
is the existing `PlatformRole.admin` enforced first in every use-case (decision
#2); every admin action is audited into ONE append-only `admin.audit_log`
covering all admin verbs (decision OPEN-B), with the cross-user support read
fail-closed and the trail immutable against every role including service; the
user sanction is a reversible suspend/reinstate pair with a mandatory reason
(decision OPEN-A), reusing existing use-cases everywhere an equivalent exists
(decision #1); and the phase ships backend routes only, no UI (decision #3). The
one production compile break (DEFECT AD-1) is closed; the one misleading
dartdoc (AD-2) is fixed. Verification is by-construction (§2 environment note);
"compiles & goes green" is to be confirmed via `melos bootstrap && melos run
verify` on a Dart-3.12+ machine, and the DB-gated integration test in CI against
an ephemeral Postgres with migrations 0001–0010 applied. **Admin Panel phase
COMPLETE & RATIFIED.** Next phase: Flutter App (phase 12).
