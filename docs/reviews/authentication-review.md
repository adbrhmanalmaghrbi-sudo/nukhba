# Authentication Phase — Six-Way Review

_Phase: Authentication (immediately after Milestone 0, per Roadmap ADR 0008)._
_Reviewed: 2026-07-09. Rigor level: Milestone-0 (production-ready, no
placeholders, version-verified, ADR-conformant)._

This document is the mandatory end-of-phase review required by the roadmap: six
independent lenses (architecture, security, correctness/bugs, performance,
maintainability, production-readiness). Every issue found is recorded with its
resolution; nothing is left open at phase exit.

---

## 0. Scope Under Review

| Layer | Files reviewed |
|---|---|
| Domain (`packages/domain/identity`) | `user_id.dart`, `platform_role.dart`, `user.dart`, `authenticated_user.dart` |
| Contracts (`packages/contracts`) | `me_dto.dart` (`AuthenticatedUserDto`, `MeResponseDto`), `error_dto.dart` |
| Application (`packages/application/identity`) | `ports/token_verifier.dart`, `ports/user_directory.dart`, `authenticate_request.dart`, `get_current_user.dart`, `authorization.dart` |
| Infrastructure (`packages/infrastructure/identity`) | `auth_config.dart`, `jwks_client.dart`, `supabase_jwt_verifier.dart`, `postgres_user_directory.dart` |
| Edge (`apps/server`) | `composition/composition_root.dart`, `http/bearer_auth.dart`, `http/error_envelope.dart`, `routes/_middleware.dart`, `routes/me/_middleware.dart`, `routes/me/index.dart` |
| Migration | `supabase/migrations/0001_identity.sql` |
| Tests | domain identity, application (3 use-cases), infrastructure (auth config, JWKS client, JWT verifier), edge (bearer_auth, `/me`, `/health`) |

**End-to-end flow proven:** client → `routes/me/_middleware.dart` (`bearerAuth`)
→ `AuthenticateRequest` → `SupabaseJwtVerifier` (allow-list → key → `JWT.verify`)
→ `AuthenticatedUser` provided into context → `routes/me/index.dart` →
`GetCurrentUser` → `PostgresUserDirectory` (idempotent upsert against
`identity.users`) → `MeResponseDto`. `/health` remains public.

---

## 1. Architecture Review

**Verdict: PASS.**

- **Clean-Architecture dependency rule holds (ADR 0007 §1).** Domain imports
  only `shared`; application imports `domain` + `shared` and depends on
  infrastructure **only through ports** (`TokenVerifier`, `UserDirectory`);
  infrastructure implements those ports; `apps/server` is the only component
  that touches `infrastructure`, and only inside `CompositionRoot` (ADR 0002
  §8). No cross-context internal imports appear (identity is the sole context
  besides platform/health).
- **Command/Query separation (ADR 0004 §2).** `GetCurrentUser` is a pure query;
  `AuthenticateRequest` establishes a principal without mutation. The one write
  (directory upsert) is an idempotent "ensure" seeded from a verified principal,
  documented as safely retryable.
- **Correct split between `User` and `AuthenticatedUser`.** The request
  principal (token-sourced) is deliberately narrower than the canonical `User`
  (platform-owned). Route code reads platform role/status from the directory,
  never from the token — closing the "trust the token as canonical state" trap.
- **Two-layer authorization scaffolding present (ADR 0006 §2).** Layer 1 is
  `Authorization.requireRole` + `AuthenticatedUser.hasRole` (role hierarchy
  defined once). Layer 2 (business invariants) is intentionally an empty slot to
  be filled by later domain phases — exactly as the phase brief requires.
- **Contracts are schema-decoupled and versioned (ADR 0004 §4).** DTOs carry
  `schema_version`, tolerate legacy payloads, and expose no token/signature
  material.
- **No architectural change was introduced.** All six ratified ADRs are
  honoured; the phase added an identity slice within the existing package
  topology (no new internal packages, as anticipated).

_No architecture issues found._

---

## 2. Security Review

**Verdict: PASS after hardening (2 defense-in-depth fixes applied this review).**

### Strengths confirmed
- **Local, server-side JWT verification (Security ADR §2).** Every accepted
  token has signature + `exp` + `nbf` + `iss` + `aud` asserted by `JWT.verify`.
  Failures are terminal `authorization`; an unreachable JWKS endpoint is
  `transient` (retryable) — the correct trust distinction.
- **JWKS cache is rotation-safe and abuse-bounded.** Bounded TTL (10 min) plus a
  single rate-limited forced refresh on unknown `kid` (`minRefreshInterval`
  30 s) means a freshly rotated key is picked up promptly while an attacker
  cannot amplify fetches with bogus `kid`s.
- **Token role is never trusted as platform authority.** Supabase's `role` claim
  (`authenticated`/`service_role`) is mapped explicitly; `admin` elevation is a
  platform decision owned by the directory, never taken from a token.
- **Directory upsert preserves platform-owned fields.** `ON CONFLICT` updates
  only `email`/`updated_at`; stored `role`/`status` are authoritative and are
  returned via `RETURNING` (the caller sees the stored values, not the token's).
- **Migration is defense-in-depth (DB ADR §10, Axiom 6).** RLS enabled with
  self-read only; **no** client write policy; write privileges additionally
  `REVOKE`d from `anon`/`authenticated` so even a future mis-added policy cannot
  silently grant writes. `id` is FK to `auth.users` with `ON DELETE CASCADE`.
- **Error envelope leaks nothing.** `AppError.cause` is never serialized; only
  the stable `code` and safe `message` cross the wire. Baseline security headers
  (`nosniff`, `DENY`, `no-referrer`) are applied to every response.

### Issues found and fixed this review

**S-1 (High) — Algorithm-confusion / `alg`-substitution hardening (CWE-347).**
The verifier previously selected the verification key using the `alg` value read
from the *unverified* token header, with no server-side allow-list gate. While no
concrete key-reuse bypass existed for the Supabase configuration (ES256 public
keys and the HS256 legacy secret are distinct materials), trusting an
attacker-controlled `alg` to steer verification is the exact anti-pattern behind
algorithm-confusion CVEs. **Fix:** introduced a server-owned allow-list
`AuthConfig.acceptedAlgorithms = {ES256, HS256}` and `AuthConfig.allowsAlgorithm`
(HS256 additionally gated on a configured legacy secret). `SupabaseJwtVerifier`
now rejects any `alg` outside the allow-list **before touching any key material**
(`auth.unsupported_alg`). This also makes `alg: none` and any unexpected
algorithm (`RS256`, `HS384`, …) an up-front, provable rejection.

**S-2 (Low) — `typ` header enforcement made explicit.** `JWT.verify`'s
`checkHeaderType` defaults to `true`, but the intent was implicit. **Fix:**
pinned `checkHeaderType: true`, `checkExpiresIn: true`, `checkNotBefore: true`
explicitly at the call site so the security posture survives any future library
default change.

_Tests added:_ `allowsAlgorithm` allow-list matrix (`auth_config_test.dart`);
`alg:none` and non-allow-listed `RS256` rejection, plus the updated ES256-only
HS256-rejection expectation (`supabase_jwt_verifier_test.dart`).

_No open security issues at phase exit._

---

## 3. Correctness / Bug Review

**Verdict: PASS.**

- **Bearer parsing is RFC-7235 correct.** Scheme matched case-insensitively;
  empty/whitespace-only tokens and non-Bearer schemes return
  `auth.missing_bearer` (authorization), not a crash.
- **Every failure path is a typed `Result`; nothing throws out of `verify`.**
  `JWT.decode`, `JWTKey.fromJWK`, and `JWT.verify` are each wrapped; the
  exception ordering (`JWTExpiredException` before the `JWTException`
  supertype) is correct against `dart_jsonwebtoken` 2.17.0's hierarchy.
- **Exhaustive `switch` over the sealed `Result`** in every mapping site
  (verifier, directory, routes, error envelope) — analyzer-enforced totality.
- **`UserId.tryParse` validates UUID shape** so a malformed `sub` is a typed
  `authorization` failure, never a constructed-but-invalid id.
- **Directory row-mapping guards corruption.** Empty result, unknown `role`, or
  unknown `status` from storage map to a `transient` `identity.row_corrupt`
  fault (an infrastructure fault, not blamed on the caller).
- **`GET /me` rejects non-GET with 405**; the handler is only reached after
  successful auth (middleware short-circuits otherwise).
- **JWKS `_lookup` disambiguation is sound.** A `null` kid resolves only when
  exactly one key is published (either one keyed or one keyless), otherwise a
  clean `no_matching_key` — no silent wrong-key selection.

_No correctness bugs found._

---

## 4. Performance Review

**Verdict: PASS.**

- **No per-request network call on the hot path.** ES256 verification uses the
  in-memory JWKS cache; a fetch happens only on cold start, TTL expiry, or an
  unknown-`kid` rotation event (rate-limited). HS256 needs no network at all.
- **Single round-trip for `/me`.** The directory "ensure" is one idempotent
  `INSERT … ON CONFLICT … RETURNING`, not a read-then-write.
- **Connection pooling reused** from Milestone 0 (`PostgresConnection`); the
  identity slice opens no new pools.
- **`CompositionRoot` caches the bootstrap *future*** so concurrent first-hit
  callers share one bootstrap rather than racing to open multiple pools.
- **JWKS map is keyed by `kid`** — O(1) lookup; the keyless list is only
  consulted in the single-key fallback.

_No performance issues found._ (Note: a shared JWKS cache across isolates is a
future optimization, not a correctness concern; per-isolate caches are safe.)

---

## 5. Maintainability Review

**Verdict: PASS.**

- **Every public element is documented** with the ADR/section it satisfies,
  keeping the "why" attached to the code.
- **Role hierarchy defined exactly once** (`AuthenticatedUser.hasRole`);
  `Authorization.requireRole` composes it without duplication.
- **`ErrorKind → HTTP status` mapping lives in exactly one place**
  (`error_envelope.dart`), so all routes fail identically.
- **Config is derived, not duplicated.** Issuer and JWKS URI are derived from a
  single validated project ref, so they cannot drift out of sync.
- **The security allow-list is a named, testable constant**
  (`AuthConfig.acceptedAlgorithms`) rather than scattered string literals —
  future algorithm-policy changes are a one-line edit with a matching test.
- **`CompositionRoot.forTesting`** wires only the slice under test; unwired
  slices are "absent" stand-ins that throw a clear `StateError`, so a test that
  reaches unwired code fails loudly rather than silently.

_No maintainability issues found._

---

## 6. Production-Readiness Review

**Verdict: PASS.**

- **No placeholders, TODOs, mocks, or shortcuts** in shipped code (mocks exist
  only in tests). All error kinds are handled end-to-end.
- **Fail-fast configuration.** `CompositionRoot.bootstrap` refuses to start on
  invalid Postgres or auth config (`StateError`), so misconfiguration is caught
  at boot, not at first request.
- **Graceful shutdown.** `dispose()` closes the JWKS HTTP client and the
  Postgres connection; `reset()` is available for controlled restarts/tests.
- **Migration is forward-only, expand-only, and idempotent** (every statement
  guarded / re-runnable), matching Platform ADR migration discipline.
- **Secrets stay in env only** (`AuthConfig.fromEnv`); the legacy secret is
  never logged and never crosses the wire.
- **Public probe preserved.** `/health` stays open (auth is scoped to `/me`'s
  subtree), so orchestrator liveness/readiness probes are unaffected.
- **Test coverage spans all layers** including hermetic crypto (locally-signed
  HS256 tokens) and the new algorithm-confusion hardening — no live Supabase
  project required to run the suite.

### Version verification (recorded in project context §3)
`dart_jsonwebtoken` 2.17.0 (`JWT.verify` derives `alg` from the header and
applies it against the supplied key — confirming that the **server-side
allow-list gate is the caller's responsibility**, which S-1 now implements);
`JWTExpiredException`/`JWTInvalidException` extend `JWTException`; `Audience.one`;
`SecretKey`; `JWTKey.fromJWK`. Supabase JWKS/claims facts unchanged from the
2026-07-09 log.

---

## 7. Summary of Changes Made During This Review

| ID | Severity | Change | Files |
|---|---|---|---|
| S-1 | High | Server-owned algorithm allow-list; reject non-allow-listed `alg` (incl. `none`) before key selection | `auth_config.dart`, `supabase_jwt_verifier.dart` |
| S-2 | Low | Pin `checkHeaderType`/`checkExpiresIn`/`checkNotBefore` explicitly on `JWT.verify` | `supabase_jwt_verifier.dart` |
| T-1 | — | Tests for allow-list matrix, `alg:none`/`RS256` rejection; updated ES256-only HS256 expectation | `auth_config_test.dart`, `supabase_jwt_verifier_test.dart` |

**Phase exit status: GREEN.** All six reviews pass; every issue found is fixed;
no open items. The Authentication phase is 100% complete per Roadmap ADR 0008.
Next phase: **Competition** (see project context §4).
