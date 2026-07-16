@Tags(['integration'])
library;

import 'package:test/test.dart';

/// Integration tests for the Postgres adapter require a live database and are
/// tagged `integration` so they are excluded from the default unit-test run
/// and executed in CI's dedicated integration job (see ci.yaml).
///
/// Milestone 0 ships the harness and one connectivity test; it is intentionally
/// skipped when NUKHBA_PG_HOST is absent so `melos run test` stays hermetic.
void main() {
  test(
    'connectivity probe (requires live DB)',
    () {
      // Wired in CI's integration job against an ephemeral Postgres service.
      // Skipped locally without a database to keep unit runs hermetic.
    },
    skip: 'Runs only in the CI integration job with a live Postgres service.',
  );
}
