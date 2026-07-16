import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// Persistence port for the actual **fixture results** — the single football
/// seam Scoring needs to compare a prediction against (Axiom 3; Next-Task
/// decision 2026-07-11: option (a), a minimal `FixtureResult` fed by an admin
/// ingestion command, is APPROVED and MANDATORY).
///
/// Backed by `PostgresFixtureResultRepository` over the new
/// `scoring.fixture_results` table. The interface speaks in the domain
/// [FixtureResult] value object and typed [FixtureRef], never in rows or SQL,
/// so use-cases stay pure and testable against an in-memory fake.
///
/// This is deliberately its own port rather than a method on the Prediction or
/// Competition repository: a result is owned by Football Data (Axiom 3), is
/// keyed by fixture only (no competition/round reference), and the same fixture
/// may feed many rounds — so binding a result to a round for scoring is the
/// scoring use-case's job, not this port's.
///
/// General contract for every method (Application ADR, Section 2):
/// * MUST NOT throw — every outcome is a typed [Result].
/// * MUST map infrastructure failures to [ErrorKind.transient].
/// * MUST map a storage-only integrity conflict to [ErrorKind.invariant].
abstract interface class FixtureResultRepository {
  /// Records the actual [result] for its fixture, upserting in place so an
  /// admin can correct a mistyped scoreline before scoring (Axiom 6: the client
  /// never writes results; only an admin command reaches this port). Idempotent
  /// on the fixture id — recording the same result twice is a no-op-equivalent.
  ///
  /// [recordedAt] (UTC) is the ingestion instant the adapter stamps for audit.
  Future<Result<void>> upsert(FixtureResult result, DateTime recordedAt);

  /// Returns the recorded actual result for [fixture], or `Ok(null)` when no
  /// result has been ingested yet (scoring a round then fails the missing-result
  /// invariant rather than guessing).
  Future<Result<FixtureResult?>> findByFixture(FixtureRef fixture);

  /// Returns the recorded results for every fixture in [fixtures], in an
  /// unspecified order (the scoring use-case re-keys them by fixture id). A
  /// fixture with no recorded result is simply absent from the returned list —
  /// the caller detects the gap by count, never by a fabricated zero.
  Future<Result<List<FixtureResult>>> findByFixtures(List<FixtureRef> fixtures);
}
