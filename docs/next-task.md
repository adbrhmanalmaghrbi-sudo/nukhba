# Next Task

## Resume From: Step 4 — Static analysis (Build Verification Gate)

**Last Completed Step:** Step 3 (build_runner, verified present).

---

## Status Update (2026-07-21)

The two fixes previously listed here as "still open" have been **CONFIRMED ALREADY APPLIED** in the current source:

1. **apps/server/test/routes/ledger_routes_test.dart**  
   `storedScore()` already passes `totalPoints: total` to `RoundScore.fromStored(...)`.  
   ✅ **DONE**

2. **packages/application/test/competition/fake_competition_repository.dart**  
   Class is now `base class FakeCompetitionRepository`, which permits the `extends` in `join_competition_test.dart`.  
   ✅ **DONE**

---

## No Further Source Edits Pending

All previously tracked source-level fixes are applied.  
**The remaining work is VERIFICATION, not new fixes.**

---

## Exact Next Command

**Environment requirement:** Capable machine with ≥ 8 GB RAM  
(NOT the old 985 MiB sandbox. GitHub Codespaces or local machine.)

```bash
dart pub get
dart run build_runner build --delete-conflicting-outputs
dart analyze --fatal-infos --fatal-warnings .
