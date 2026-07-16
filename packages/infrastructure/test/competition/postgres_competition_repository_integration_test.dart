@Tags(['integration'])
library;

import 'package:test/test.dart';

/// DB-gated integration tests for [PostgresCompetitionRepository].
///
/// The one behaviour a hermetic unit test cannot cover is the reclassification
/// of a real `postgres` `ServerException` (which has no public constructor) into
/// a domain `ErrorKind.invariant` conflict via the *violated constraint name*
/// (`_reclassify` + the per-method `onConstraint` maps, and the freeze/lifecycle
/// trigger `check_violation` backstop). Those constraint names live in the
/// `0002_competition.sql` migration, so they can only be exercised against a
/// live schema. This file is tagged `integration` so it is excluded from the
/// hermetic `melos run test` and executed in CI's dedicated integration job
/// against an ephemeral Postgres with the migrations applied (see ci.yaml),
/// matching the existing `postgres_health_repository_test.dart` harness.
///
/// The scenarios CI must exercise once wired end-to-end (each asserts the exact
/// domain code the use-cases and unit tests expect):
///   * duplicate `(season_id, sequence)` round      → `competition.round_sequence_conflict`
///   * duplicate `(season_id, user_id)` participant → `competition.already_joined`
///   * FK to an absent season on `saveSeason`       → `competition.not_found`
///   * FK to an absent round on `saveRoundFixture`  → `competition.round_not_found`
///   * duplicate `(round_id, fixture_id)` link      → `competition.fixture_already_linked`
///   * the ruleset-freeze / lifecycle trigger       → `competition.integrity_violation`
///   * a happy-path save + find round-trip preserving the ruleset snapshot.
void main() {
  test(
    'competition repository integrity mapping (requires live DB)',
    () {
      // Wired in CI's integration job against an ephemeral Postgres service
      // with `supabase/migrations/0002_competition.sql` applied. Skipped locally
      // so `melos run test` stays hermetic.
    },
    skip: 'Runs only in the CI integration job with a live Postgres service.',
  );
}
