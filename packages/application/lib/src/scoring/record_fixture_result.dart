import 'package:application/src/common/clock.dart';
import 'package:application/src/identity/authorization.dart';
import 'package:application/src/scoring/ports/fixture_result_repository.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// Use-case: record the actual final score of a fixture (Application ADR,
/// Section 2: command intent `RecordFixtureResult`).
///
/// This is the admin ingestion command behind the Axiom-3 football seam
/// (Next-Task decision 2026-07-11, option (a)): the platform has no
/// Football-Data phase before Scoring, so the actual scoreline enters through
/// this minimal admin command rather than an automated feed. The client never
/// submits a result (Axioms 2/5 integrity boundary): the caller must hold the
/// **admin** platform role, and a fixture result carries no competition/round
/// reference — the same result may feed many rounds (Axiom 3).
///
/// Idempotent (Application ADR, Section 2): recording a result for a fixture
/// upserts in place, so an admin can correct a mistyped scoreline before the
/// round is scored, and a retried call converges on the same stored value.
///
/// Never throws; returns a typed [Result].
final class RecordFixtureResult {
  /// Creates the use-case over its collaborators.
  const RecordFixtureResult({
    required FixtureResultRepository resultRepository,
    required Clock clock,
  }) : _results = resultRepository,
       _clock = clock;

  final FixtureResultRepository _results;
  final Clock _clock;

  /// Records that [fixtureId] finished [homeGoals]–[awayGoals], on behalf of the
  /// admin [principal]. Validates the id and the scoreline (via the domain
  /// [FixtureResult.create]) before touching storage.
  Future<Result<FixtureResult>> call({
    required AuthenticatedUser principal,
    required String fixtureId,
    required int homeGoals,
    required int awayGoals,
  }) async {
    // Layer 1: only an admin may ingest actual results (Axioms 2/5).
    final auth = Authorization.requireRole(principal, PlatformRole.admin);
    if (auth is Err<AuthenticatedUser>) {
      return Result.err(auth.error);
    }

    final fixtureResult = FixtureRef.tryParse(fixtureId);
    if (fixtureResult is Err<FixtureRef>) {
      return Result.err(fixtureResult.error);
    }
    final fixture = (fixtureResult as Ok<FixtureRef>).value;

    // Domain validation: non-negative, within the shared goal ceiling.
    final resultResult = FixtureResult.create(
      fixture: fixture,
      homeGoals: homeGoals,
      awayGoals: awayGoals,
    );
    if (resultResult is Err<FixtureResult>) {
      return Result.err(resultResult.error);
    }
    final result = (resultResult as Ok<FixtureResult>).value;

    final saved = await _results.upsert(result, _clock.nowUtc());
    return switch (saved) {
      Ok<void>() => Result.ok(result),
      Err<void>(:final error) => Result.err(error),
    };
  }
}
