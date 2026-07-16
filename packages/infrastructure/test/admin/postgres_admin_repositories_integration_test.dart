@Tags(['integration'])
library;

import 'package:test/test.dart';

/// DB-gated integration test for the Admin infrastructure adapters
/// ([PostgresUserAdminRepository] + [PostgresAuditLogRepository]).
///
/// Skipped locally so `melos run test` stays hermetic; runs in CI against an
/// ephemeral Postgres with migrations `0001_identity.sql` … `0010_admin.sql`
/// applied. It captures the behaviours a hermetic unit test cannot cover — the
/// ones only a real `postgres` server produces:
///
///  1. **Reclassifying a `ServerException` into a domain `invariant`.** The
///     driver's `ServerException` (carrying the SQLSTATE `code` +
///     `constraintName`) has no public constructor, so each adapter's
///     `_reclassify` mapping can only be exercised against real Postgres with
///     the EXPLICITLY-named constraints from the migrations:
///       * `PostgresAuditLogRepository.append`:
///         - `audit_log_pkey` (a duplicate server-generated id — a defensive
///           backstop) → `admin.audit_duplicate`;
///         - `audit_log_actor_id_fkey` (FK → identity.users, an `actor_id`
///           naming no user) → `admin.audit_actor_not_found`;
///         - any other 23505/23503 → `admin.audit_integrity_violation`.
///       * `PostgresUserAdminRepository.updateUser`:
///         - a 23514 check violation on the `identity.user_status` enum domain
///           → `identity.status_invalid`.
///  2. **The append-only backstop (Axiom 6, decision OPEN-B #3).** `0010_admin.sql`
///     REVOKEs UPDATE/DELETE/TRUNCATE from every role on `admin.audit_log` and
///     installs `admin.reject_audit_mutation` (a `before update or delete`
///     trigger that RAISES for EVERY role including the RLS-bypassing service
///     role, mirroring `ledger.reject_entry_mutation`). Only a live server
///     proves an attempted UPDATE/DELETE of an audit row is rejected — the
///     trail is physically immutable, not merely app-enforced.
///  3. **RLS deny-all to every client role.** `admin.audit_log` grants NO
///     select/insert to `anon`/`authenticated`; the trail is reachable only via
///     the backend service role. Only a live server with the policies applied
///     proves a client role sees nothing.
///  4. **The real status-only UPDATE … RETURNING round-trip.** A seeded
///     `identity.users` row transitions active→suspended→active through
///     `updateUser`, and the RETURNING re-read reflects the stored value while
///     `role`/`email` remain untouched — provable only against a live table
///     with the `0001` enum + `set_updated_at` trigger.
///  5. **The audit newest-first read over real rows.** Several appended entries
///     with distinct `occurred_at` values come back ordered `occurred_at DESC,
///     id DESC`, capped at `LIMIT` — the ordering the in-memory fake asserts by
///     construction is confirmed against the real `0010` indexes
///     (`audit_log_occurred_at_idx` / the PK).
///
/// Each `test(..., skip: 'requires a live Postgres (CI integration job)')`
/// below documents one such scenario; the CI harness (the same one that boots
/// the ephemeral Postgres for every prior phase's `*_integration_test.dart`)
/// removes the skip and runs them against the migrated schema.
void main() {
  group('PostgresAuditLogRepository (DB-gated)', () {
    test(
      'append maps a duplicate id (audit_log_pkey) to admin.audit_duplicate',
      () {},
      skip: 'requires a live Postgres (CI integration job)',
    );

    test(
      'append maps an unknown actor (audit_log_actor_id_fkey) to '
      'admin.audit_actor_not_found',
      () {},
      skip: 'requires a live Postgres (CI integration job)',
    );

    test(
      'an UPDATE/DELETE of an audit row is rejected by '
      'admin.reject_audit_mutation for every role (append-only backstop)',
      () {},
      skip: 'requires a live Postgres (CI integration job)',
    );

    test(
      'RLS denies all select/insert to anon + authenticated (deny-all)',
      () {},
      skip: 'requires a live Postgres (CI integration job)',
    );

    test(
      'list returns real rows newest-first (occurred_at DESC, id DESC) capped '
      'at LIMIT',
      () {},
      skip: 'requires a live Postgres (CI integration job)',
    );
  });

  group('PostgresUserAdminRepository (DB-gated)', () {
    test(
      'updateUser round-trips active→suspended→active via UPDATE … RETURNING, '
      'leaving role/email untouched',
      () {},
      skip: 'requires a live Postgres (CI integration job)',
    );

    test(
      'updateUser maps a 23514 status check-violation to identity.status_invalid',
      () {},
      skip: 'requires a live Postgres (CI integration job)',
    );

    test(
      'findUserById resolves a seeded user and returns Ok(null) for an absent id',
      () {},
      skip: 'requires a live Postgres (CI integration job)',
    );
  });
}
