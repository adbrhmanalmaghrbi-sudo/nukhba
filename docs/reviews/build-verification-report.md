# Build Verification Report

> Launch-readiness gate for the Nukhba platform (post-roadmap, ratified in
> `docs/project-context.md` §4). One row per step: exact command, PASS/FAIL,
> and literal recorded output (or a faithful excerpt with real counts).
> **Nothing here is inferred — every verdict is backed by literal command
> output captured this session.**

_Created: 2026-07-15 (session 2). Environment: Genspark sandbox, Debian, x86_64,
985 MiB RAM (~610–720 MiB available), 27 G disk. Flutter **3.44.0** / Dart
**3.12.0** re-installed to `/home/user/flutter` (not bundled in the archive),
matching `.fvmrc` and `pubspec.lock`. No Android SDK, no macOS/Xcode._

---

## Summary

| # | Step | Command | Verdict |
|---|------|---------|---------|
| 1 | Workspace deps | `flutter pub get` (workspace root) | ✅ PASS |
| 2 | `apps/mobile` deps | covered by workspace resolution | ✅ PASS |
| 3 | Codegen | `dart run build_runner build` (6× `.g.dart`) | ✅ PASS (pre-existing, verified present) |
| 4 | Static analysis | `flutter analyze` → fallback `dart analyze --fatal-infos --fatal-warnings .` | 🔴 **FAIL** — 307 issues (168 errors, 0 warnings, 119 info), exit code 3 |
| 5 | Tests | `flutter test` / `dart test` | ⬜ NOT RUN — blocked by step 4 (analysis errors are compile errors) |
| 6 | `flutter build web` | — | ⬜ NOT RUN — blocked by step 4 |
| 7 | `flutter build apk` | — | ⛔ BLOCKED — no Android SDK in sandbox |
| 8 | `flutter build ios` | — | ⏭️ SKIPPED — no macOS/Xcode |

**Gate verdict: 🔴 NOT GREEN.** Step 4 fails with 168 analyzer **errors**
(compile-level, not lint). The gate stops here per §4 ("do not start [step 5]
until step 4 is GREEN"). Steps 5–8 were not run because the errors are
`undefined_identifier` / `non_type_as_type_argument` / `cast_to_non_type`
class errors that would also fail compilation/test loading.

---

## Step 1 — `flutter pub get` (workspace root) — ✅ PASS

**Command:** `flutter pub get` (run from `/home/user/webapp/nukhba`)

**Literal tail of output:**
```
  uuid 4.5.3 (4.6.0 available)
  vector_math 2.2.0 (2.4.0 available)
  xml 6.6.1 (7.0.1 available)
Got dependencies!
23 packages have newer versions incompatible with dependency constraints.
Try `flutter pub outdated` for more information.
```
Exit code: 0. Versions match `pubspec.lock`. ("newer versions … incompatible"
is the normal pinned-constraint notice, not an error.)

## Step 2 — `apps/mobile` deps — ✅ PASS

`apps/mobile` declares `resolution: workspace` and is a member of the root
`workspace:` list in `pubspec.yaml`, so it is resolved by step 1. No separate
`pub get` needed. Confirmed by the presence of a resolved `pubspec.lock` and a
successful analysis load of the `apps/mobile` tree in step 4 (the errors there
are missing-import errors in test files, not unresolved-dependency errors).

## Step 3 — `dart run build_runner build` — ✅ PASS (pre-existing)

All 6 generated files are present on disk (verified this session; not
regenerated, source unchanged):
```
apps/mobile/lib/core/providers.g.dart
apps/mobile/lib/features/auth/session_controller.g.dart
apps/mobile/lib/features/competition/competition_providers.g.dart
apps/mobile/lib/features/prediction/prediction_providers.g.dart
apps/mobile/lib/features/prediction/prediction_controller.g.dart
apps/mobile/lib/features/leaderboards/leaderboards_providers.g.dart
```

## Step 4 — Static analysis — 🔴 FAIL

**Primary command attempted:** `flutter analyze`
**Result:** Did NOT complete. Ran > 510 s (past the 400 s point that timed out
in session 1) with no verdict; the `dart language-server` it spawns pinned
~68 % of the 985 MiB RAM (≈695 MiB RSS) and never finished on this
RAM-constrained sandbox. Killed and fell back to the canonical command below
(exactly as §4 authorizes: "or `dart analyze --fatal-infos --fatal-warnings .`
if `flutter analyze` again times out on this sandbox"). Partial log saved to
`docs/reviews/analyze-flutter-session2-timedout.txt`.

**Fallback command (the melos `analyze` script, run from
`/home/user/webapp/nukhba`):**
```
dart analyze --fatal-infos --fatal-warnings .
```

**Literal result line + exit code (last lines of output):**
```
   info - packages/infrastructure/test/scoring/postgres_scoring_repositories_test.dart:433:39 - Use 'const' with the constructor to improve performance. Try adding the 'const' keyword to the constructor invocation. - prefer_const_constructors

307 issues found.
EXITCODE=3
```

**Severity breakdown (literal counts from the captured output):**
- `error`   : **168**
- `warning` : 0
- `info`    : 119
- **Total: 307 issues; exit code 3 (FAIL).**

Full raw output saved verbatim to `docs/reviews/analyze-raw-session2.txt`
(312 lines).

### Errors grouped by file (all 168)
```
 30  apps/server/test/routes/group_routes_test.dart
 23  apps/server/test/routes/social_routes_test.dart
 23  apps/server/test/routes/scoring_routes_test.dart
 19  apps/server/test/routes/notifications_routes_test.dart
 12  apps/server/test/routes/admin_routes_test.dart
 10  apps/server/test/routes/ledger_routes_test.dart
  7  apps/server/test/routes/round_predictions_test.dart
  6  apps/server/test/routes/seasons_rounds_browse_test.dart
  6  apps/server/test/routes/season_leaderboard_test.dart
  6  apps/server/test/routes/rounds_browse_test.dart
  4  apps/mobile/test/support/prediction_harness.dart
  4  apps/mobile/test/support/leaderboards_harness.dart
  4  apps/mobile/test/support/competition_harness.dart
  3  apps/server/test/routes/season_participants_test.dart
  3  apps/mobile/test/support/auth_harness.dart
  2  apps/server/test/routes/season_rounds_test.dart
  2  apps/server/routes/groups/[id]/feed/index.dart   <-- ONLY production-code file
  1  packages/domain/test/competition/ids_and_enums_test.dart
  1  packages/application/test/group/get_group_leaderboard_test.dart
  1  packages/application/test/competition/join_competition_test.dart
  1  apps/server/test/routes/competition_seasons_test.dart
```

### Errors grouped by analyzer rule (all 168)
```
120  undefined_identifier            (mostly `HttpMethod` in route tests)
 25  non_type_as_type_argument       (`Override`, `Response`, `ActivityEvent`)
 10  undefined_getter                (`count` on In-memory repos, scoring test)
  5  cast_to_non_type                (`Ok` used in `as` casts)
  3  undefined_function              (`InMemoryTokenStore`, mobile harnesses)
  2  missing_required_argument       (`totalPoints`, ledger/scoring tests)
  1  wrong_number_of_type_arguments_element  (`isNot<...>`)
  1  invalid_use_of_type_outside_library     (extending a `final` FakeCompetitionRepository)
  1  argument_type_not_assignable    (`dynamic` → `HttpMethod`)
```

### Root-cause read (for the next executor — NOT yet fixed this session)
The errors are overwhelmingly **missing / wrong imports and a few drifted
test helpers**, not broken business logic:

1. **`undefined_identifier: HttpMethod` (120, all in `apps/server/test/routes/*`)**
   — the route tests reference `HttpMethod.get/post/...` without importing the
   library that exports `HttpMethod` (dart_frog). Very likely a shared test
   harness/import that was renamed or dropped.
2. **`non_type_as_type_argument: 'Response'` / `'Override'` / `'ActivityEvent'`**
   — same class of missing import:
   - `'Response'` (dart_frog) missing in several route tests.
   - `'Override'` (Riverpod `ProviderContainer` overrides) missing in the
     `apps/mobile/test/support/*_harness.dart` files.
   - **`'ActivityEvent'` in `apps/server/routes/groups/[id]/feed/index.dart`
     (lines 54, 57) — the ONE production-code error.** The file uses
     `Ok<List<ActivityEvent>>` / `Err<List<ActivityEvent>>` but does **not**
     `import 'package:application/application.dart';` (it imports domain,
     server, shared, and the social_dto_mapper only). `ActivityEvent` is
     defined in `packages/application/lib/src/social/activity_event.dart`.
3. **`cast_to_non_type: 'Ok'` (5)** — tests using `... as Ok<...>` without the
   `shared` import that defines `Ok`/`Err`.
4. **`undefined_function: InMemoryTokenStore` (3)** — the mobile harnesses call
   a token-store helper that isn't imported/defined.
5. **`undefined_getter: count` (2, scoring route test)** — the in-memory
   repos in the harness apparently no longer expose a `count` getter the test
   still reads.
6. **`missing_required_argument: totalPoints` (2)** — ledger/scoring route
   tests build a DTO/value without the now-required `totalPoints`.
7. **`invalid_use_of_type_outside_library` (1)** — `join_competition_test.dart`
   extends `FakeCompetitionRepository`, which is now declared `final`.
8. **`wrong_number_of_type_arguments_element: isNot` (1)** — a test wrote
   `isNot<T>(...)`; `isNot` takes no type argument.

These are all fixable at the source (imports + a few test-helper realignments)
without touching ratified business logic, ADRs, `analysis_options.yaml`, or any
of the 12 completed phases — consistent with §4's "fix the root cause in source"
rule. The single production-code fix (#2, `feed/index.dart` import) should be
made first; the rest are in `test/` and test-support files.

> **Note on the 119 `info` issues:** with `--fatal-infos`, these also count
> toward the non-zero exit. They are style-only
> (`prefer_const_constructors` 73, `directives_ordering` 26,
> `unnecessary_import` 6, `use_null_aware_elements` 6, etc.) and are auto-
> fixable with `dart fix --apply`. They do NOT block compilation, but they DO
> block a `--fatal-infos` GREEN, so they must be resolved (or the run re-scoped)
> for step 4 to pass.

## Steps 5–8 — NOT RUN

Per §4 the sequence must be GREEN in order; step 4 failed, so:
- **Step 5 (`flutter test` / `dart test`)** — not started. The step-4 errors
  are compile-level (`undefined_identifier`, `non_type_as_type_argument`), so
  the affected test libraries would fail to load anyway.
- **Step 6 (`flutter build web`)** — not started (blocked by step 4; note the
  one production error in `feed/index.dart` would fail the server build, though
  it is not in the `apps/mobile` web target).
- **Step 7 (`flutter build apk`)** — BLOCKED: no Android SDK in this sandbox.
- **Step 8 (`flutter build ios`)** — SKIPPED: no macOS/Xcode.

---

## Honest gate status

🔴 **The Build Verification Gate is NOT GREEN.** `dart analyze
--fatal-infos --fatal-warnings .` returns **168 errors** (exit code 3). This is
recorded here verbatim; no PASS is claimed. The next execution session must fix
the root causes in source (starting with the single production import in
`apps/server/routes/groups/[id]/feed/index.dart`, then the test/test-support
imports and helper drift, then the 119 style infos), then re-run the full
sequence from step 4.
