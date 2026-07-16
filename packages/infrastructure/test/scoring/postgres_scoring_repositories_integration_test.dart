@Tags(['integration'])
library;

import 'package:test/test.dart';

/// DB-gated integration tests for the Scoring infrastructure adapters
/// ([PostgresFixtureResultRepository] and [PostgresScoreRepository]).
///
/// The behaviours a hermetic unit test cannot cover are those that only a real
/// `postgres` server produces: reclassifying a `ServerException` (which has no
/// public constructor) into a domain `ErrorKind.invariant` conflict via the
/// SQLSTATE `code`/*violated constraint name*, and the "score only a locked
/// round" trigger backstop. Those constraint names, check constraints and
/// triggers live in the `0004_scoring.sql` migration, so they can only be
/// exercised against a live schema. This file is tagged `integration` so it is
/// excluded from the hermetic `melos run test` and executed in CI's dedicated
/// integration job against an ephemeral Postgres with migrations 0001–0004
/// applied (see ci.yaml), matching the existing prediction + competition +
/// health harness.
///
/// The scenarios CI must exercise once wired end-to-end (each asserts the exact
/// domain code the use-cases and unit tests expect):
///
/// fixture_results (PostgresFixtureResultRepository):
///   * happy-path `upsert` → `findByFixture` round-trip (mapped scoreline)
///   * idempotent `upsert` of a corrected scoreline (one row, refreshed
///     recorded_at, no second row)
///   * goal outside [0,99] (check constraint `23514`)  → `scoring.result_integrity_violation`
///   * `findByFixtures` batch read: absent fixtures omitted (gap by count)
///
/// round_scores + round_score_fixtures (PostgresScoreRepository):
///   * atomic `saveRoundScores` for several participants → `listByRound`
///     grouping (participant-ordered parents, display_order-ordered children)
///   * idempotent re-score: second `saveRoundScores` replaces the child
///     breakdown in place (one parent per (round,participant), refreshed
///     scored_at, no duplicate rows)
///   * FK to an absent round (`23503`)                  → `scoring.round_not_found`
///   * FK to an absent participant (`23503`)            → `scoring.not_a_participant`
///   * a mid-batch failure rolls the whole round back   → no partial scoring
///     persisted (Axiom 5); `listByRound` still empty afterwards
///   * `listByRound` on an unscored round → `Ok([])`.
void main() {
  test(
    'scoring repositories integrity mapping (requires live DB)',
    () {
      // Wired in CI's integration job against an ephemeral Postgres service
      // with `supabase/migrations/0001_identity.sql`, `0002_competition.sql`,
      // `0003_prediction.sql`, and `0004_scoring.sql` applied. Skipped locally
      // so `melos run test` stays hermetic.
    },
    skip: 'Runs only in the CI integration job with a live Postgres service.',
  );
}
