# Progress — Build Verification Gate

_Source: docs/reviews/build-verification-report.md (session 2, 2026-07-15)._

## Completed
- Step 1: `pub get` (workspace root) — ran, exit 0.
- Step 2: `apps/mobile` deps — covered by workspace resolution.
- Step 3: build_runner (6× `.g.dart`) — files present on disk, verified.

## Verified
- Step 1 output: "Got dependencies!", versions match `pubspec.lock`.
- Step 3: 6 generated files confirmed present (listed in report).
- Step 4 command ran to completion (fallback command, ~90s): literal output captured in `docs/reviews/analyze-raw-session2.txt`. This is the last actual run — no newer run exists in this archive.

## Pending
- Step 4 re-run: NOT DONE. All fixes below are source edits only, unverified by `dart analyze`.
- Step 5: tests — NOT RUN (blocked by Step 4).
- Step 6: `flutter build web` — NOT RUN (blocked by Step 4).
- Step 8: `flutter build ios` — SKIPPED (no macOS/Xcode).

## Failed
- Step 4: `dart analyze --fatal-infos --fatal-warnings .` — **FAIL** (last recorded run). `307 issues found.` / exit code 3 (168 errors, 0 warnings, 119 info).
  - Primary command `flutter analyze` did not complete (>510s, killed) before fallback was run.

## Manual Fixes Applied (source edits only — NOT YET RE-VERIFIED via `dart analyze`)
Confirmed present by direct file inspection of this archive:
- `apps/server/routes/groups/[id]/feed/index.dart`: `import 'package:application/application.dart';` added.
- `apps/server/test/routes/competition_route_harness.dart`: `export 'package:dart_frog/dart_frog.dart';` added; `count` getter added to both fake fixture/score repos.
- `apps/server/test/routes/competition_seasons_test.dart`, `season_rounds_test.dart`, `season_participants_test.dart`: `import 'package:shared/shared.dart';` added.
- `apps/server/test/routes/season_participants_test.dart`: reverted to plain `HttpMethod.get` (the 30-line throwing indirection flagged previously is gone).
- `apps/server/test/routes/scoring_routes_test.dart`: `totalPoints: 3` added to the missing-argument call site.
- `apps/mobile/test/support/{auth,competition,leaderboards,prediction}_harness.dart`: `import 'package:flutter_riverpod/misc.dart' show Override;` added; `competition_harness.dart` and `leaderboards_harness.dart` also gained `import 'package:mobile/core/auth/token_store.dart';`.

## Still Open (confirmed by direct inspection, not fixed in this archive)
- `apps/server/test/routes/ledger_routes_test.dart`: `storedScore()` helper calls `RoundScore.fromStored(...)` without the required `totalPoints` argument (constructor requires it — `packages/domain/lib/src/scoring/round_score.dart:37`). Same class of error as the one fixed in `scoring_routes_test.dart`, not yet applied here.
- `packages/application/test/competition/fake_competition_repository.dart`: `FakeCompetitionRepository` is still declared `final class`. `packages/application/test/competition/join_competition_test.dart:157` does `final class _RacingRepository extends FakeCompetitionRepository` in a separate file — `final` classes cannot be extended outside their own library, so this will still fail to compile.

## Current Status
Build Verification Gate stopped at Step 4. Gate NOT GREEN. Steps 5–8 not executed per in-order rule. Most of the 168 tracked errors now have source fixes applied (unverified); 2 specific known issues above remain unaddressed.

## Known Issues
- 2 unaddressed fixes listed above (`ledger_routes_test.dart` totalPoints, `FakeCompetitionRepository` final/extends conflict) will still fail `dart analyze` if run now.
- 119 info-level issues (style, `--fatal-infos` makes them block) — not addressed by `dart fix --apply` in this archive (no evidence it was run).

## Risks
- `flutter build apk` (Step 7) BLOCKED in Genspark sandbox — no Android SDK. Confirmed twice (session 1 and session 2 environment notes).
- RAM-constrained sandbox (985 MiB) causes `flutter analyze` to hang/timeout; fallback command required each session.
