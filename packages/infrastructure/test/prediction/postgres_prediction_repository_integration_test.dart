@Tags(['integration'])
library;

import 'package:test/test.dart';

/// DB-gated integration tests for [PostgresPredictionRepository].
///
/// The behaviours a hermetic unit test cannot cover are those that only a real
/// `postgres` server produces: reclassifying a `ServerException` (which has no
/// public constructor) into a domain `ErrorKind.invariant` conflict via the
/// *violated constraint name*, and the "no write after lock" trigger
/// `check_violation` backstop. Those constraint names and triggers live in the
/// `0003_prediction.sql` migration, so they can only be exercised against a
/// live schema. This file is tagged `integration` so it is excluded from the
/// hermetic `melos run test` and executed in CI's dedicated integration job
/// against an ephemeral Postgres with migrations 0001–0003 applied (see
/// ci.yaml), matching the existing competition + health harness.
///
/// The scenarios CI must exercise once wired end-to-end (each asserts the exact
/// domain code the use-cases and unit tests expect):
///   * duplicate `(participant_id, round_id)` prediction → `prediction.already_submitted`
///     (the physical "predict once" backstop — SubmitPrediction pivots on it)
///   * FK to an absent round on `save`                   → `prediction.round_not_found`
///   * FK to an absent participant on `save`             → `prediction.not_a_participant`
///   * duplicate `(prediction_id, fixture_id)` score     → `prediction.duplicate_fixture`
///   * INSERT/amend against a non-open round (trigger)   → `prediction.round_not_open`
///   * goal outside [0,99] (check constraint)            → `prediction.integrity_violation`
///   * a happy-path save → find round-trip preserving the ordered forecast
///   * amend replacing the forecast in place (one row, refreshed submitted_at)
///   * `listByRound` grouping across participants, locked-round read
///   * `listRoundFixtures` reading the competition-owned link projection.
void main() {
  test(
    'prediction repository integrity mapping (requires live DB)',
    () {
      // Wired in CI's integration job against an ephemeral Postgres service
      // with `supabase/migrations/0001_identity.sql`, `0002_competition.sql`,
      // and `0003_prediction.sql` applied. Skipped locally so `melos run test`
      // stays hermetic.
    },
    skip: 'Runs only in the CI integration job with a live Postgres service.',
  );
}
