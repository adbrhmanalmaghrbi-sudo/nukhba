# Next Task

**Resume From:** Step 4 — Static analysis (Build Verification Gate). Most source fixes applied manually (see Progress.md "Manual Fixes Applied"); 2 known fixes still missing (see Progress.md "Still Open"); `dart analyze` NOT re-run — must be re-attempted, not re-opened as new work.

**Last Completed Step:** Step 3 (build_runner, verified present).

**Current Phase:** Build Verification Gate (post-12-phase), Step 4 of 8.

**Next Phase:** N/A — Step 4 must pass before Step 5 starts.

**Exact Next Command:**
Apply the 2 remaining fixes first, then run:
```
dart analyze --fatal-infos --fatal-warnings .
```
Remaining fixes (both confirmed still needed by direct inspection):
1. `apps/server/test/routes/ledger_routes_test.dart` — add required `totalPoints:` argument to the `RoundScore.fromStored(...)` call inside `storedScore()`.
2. `packages/application/test/competition/fake_competition_repository.dart` — `FakeCompetitionRepository` is `final class`; `join_competition_test.dart` extends it from another file. Either remove `final` from the class, or stop extending it in `join_competition_test.dart` — do not decide without checking why `final` was set (§3 no-guessing rule).

**Expected Result:** `No issues found!`, exit code 0.

**Success Criteria:** Literal command output shows 0 errors, 0 warnings, 0 info; exit code 0. Record verbatim in `docs/reviews/build-verification-report.md`.

**Failure Recovery:** If `flutter analyze` hangs/times out (RAM-constrained sandbox, prior timeout >400–510s), kill and fall back to `dart analyze --fatal-infos --fatal-warnings .` — this is the ratified fallback (§4), not a deviation.

**Execution Notes:**
- Do not proceed to Step 5 (tests) until Step 4 output is literally clean.
- Do not disable tests, weaken `analysis_options.yaml`, or touch ratified business logic to force a pass.
- Step 7 (`flutter build apk`) is BLOCKED in this sandbox (no Android SDK) — record as BLOCKED again if still true, do not skip silently.
