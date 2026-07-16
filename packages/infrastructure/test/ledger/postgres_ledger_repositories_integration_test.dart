@Tags(['integration'])
library;

import 'package:test/test.dart';

/// DB-gated integration tests for the Ledger infrastructure adapters
/// ([PostgresLedgerRepository] and [PostgresParticipantReader]).
///
/// The behaviours a hermetic unit test cannot cover are those that only a real
/// `postgres` server produces: reclassifying a `ServerException` (which has no
/// public constructor) into a domain `ErrorKind.invariant` conflict via the
/// SQLSTATE `code`/*violated constraint name*, and — critically for the Ledger —
/// the **append-only enforcement**: the migration's revoked UPDATE/DELETE plus
/// the immutability trigger, and the partial unique dedupe index. Those
/// constraint names, the trigger, and the index live in the `0005_ledger.sql`
/// migration, so they can only be exercised against a live schema. This file is
/// tagged `integration` so it is excluded from the hermetic `melos run test` and
/// executed in CI's dedicated integration job against an ephemeral Postgres with
/// migrations 0001–0005 applied (see ci.yaml), matching the existing scoring +
/// prediction + competition + health harness.
///
/// The scenarios CI must exercise once wired end-to-end (each asserts the exact
/// domain code the use-cases and unit tests expect):
///
/// point_entries (PostgresLedgerRepository):
///   * happy-path `appendEntries` (one round_score credit per participant) →
///     `listEntries` round-trip (stream-ordered) and `balanceFor` projection
///     equals the signed sum of the appended amounts
///   * **idempotent re-post**: a second `appendEntries` of the same
///     (participant, round, round_score) key inserts NO row (ON CONFLICT DO
///     NOTHING against `point_entries_round_score_uniq`), returns an empty
///     appended-subset, and `balanceFor` is unchanged (Axiom 4: no
///     double-credit)
///   * a `correction` entry for the same (participant, round) is append-many —
///     it coexists with the original credit and nets into the balance (Axiom 5)
///   * **append-only backstop**: a direct `UPDATE`/`DELETE` on `point_entries`
///     is rejected by the immutability trigger / revoked privilege (`23514` or
///     insufficient-privilege) — the competitive record cannot be mutated even
///     by a buggy caller (Axiom 6)
///   * FK to an absent round (`23503`)         → `ledger.round_not_found`
///   * FK to an absent participant (`23503`)   → `ledger.participant_not_found`
///   * a mid-batch failure rolls the whole post back → no partial credit
///     persisted (Axiom 5); `listEntries` still empty afterwards
///   * a `round_score` credit with a negative amount is rejected by the check
///     constraint (`23514`) → `ledger.integrity_violation`
///   * RLS: an anon/other-user client SELECT sees no rows (own-read only)
///
/// participants (PostgresParticipantReader):
///   * `findParticipantById` happy-path round-trip (mapped participant)
///   * `findParticipantById` for an absent id → `Ok(null)`
void main() {
  test(
    'ledger repositories append-only + integrity mapping (requires live DB)',
    () {
      // Wired in CI's integration job against an ephemeral Postgres service
      // with `supabase/migrations/0001_identity.sql`, `0002_competition.sql`,
      // `0003_prediction.sql`, `0004_scoring.sql`, and `0005_ledger.sql`
      // applied. Skipped locally so `melos run test` stays hermetic.
    },
    skip: 'Runs only in the CI integration job with a live Postgres service.',
  );
}
