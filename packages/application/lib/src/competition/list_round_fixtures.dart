import 'package:application/src/competition/ports/competition_repository.dart';
import 'package:application/src/identity/authorization.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// Query use-case: list the fixtures linked to a round, in matchday order
/// (Application ADR, Section 2: query separated from command).
///
/// The final browse step and the half of "Prediction (submit)" that reads the
/// open round's fixtures to render the prediction form. Added under BLOCKER
/// FA-1 (2026-07-13) as a strictly additive read over the already-migrated
/// `competition.round_fixtures` table — no new domain rule, no side effect.
///
/// This is deliberately a DIFFERENT use-case from the Prediction phase's
/// `PredictionRepository.listRoundFixtures` (which the submit/read path uses
/// internally over its own read projection): this one is the client-facing
/// Competition-context browse read, gated and shaped for the browse surface.
/// The frozen prediction port is untouched.
///
/// The caller must be an authenticated user (`PlatformRole.user`, matching
/// every other client-facing read). A round with no linked fixtures — or one
/// that does not exist — yields a legitimate empty list (no existence oracle),
/// never an error.
///
/// Never throws; returns a typed [Result].
final class ListRoundFixtures {
  /// Creates the use-case over its repository.
  const ListRoundFixtures({required CompetitionRepository repository})
    : _competition = repository;

  final CompetitionRepository _competition;

  /// Lists the fixtures linked to round [roundId], visible to [principal],
  /// ordered by display order.
  Future<Result<List<RoundFixture>>> call({
    required AuthenticatedUser principal,
    required String roundId,
  }) async {
    final auth = Authorization.requireRole(principal, PlatformRole.user);
    if (auth is Err<AuthenticatedUser>) {
      return Result.err(auth.error);
    }

    final idResult = RoundId.tryParse(roundId);
    if (idResult is Err<RoundId>) {
      return Result.err(idResult.error);
    }

    return _competition.listRoundFixtures((idResult as Ok<RoundId>).value);
  }
}
