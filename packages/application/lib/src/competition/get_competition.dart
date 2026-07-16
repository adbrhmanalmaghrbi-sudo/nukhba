import 'package:application/src/competition/ports/competition_repository.dart';
import 'package:application/src/identity/authorization.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// Query use-case: read a single competition by id (Application ADR, Section 2:
/// query separated from command).
///
/// The detail read behind the Competition-browse client scope: having listed
/// the catalogue via [ListCompetitions], a client opens one competition. Added
/// under BLOCKER FA-1 (2026-07-13) as a strictly additive read over the
/// already-migrated `competition.competitions` table — no new domain rule, no
/// side effect.
///
/// The caller must be an authenticated user (`PlatformRole.user`, matching
/// every other client-facing read). Reuses the ratified
/// [CompetitionRepository.findCompetition], which surfaces a missing
/// competition as `competition.not_found` (an `invariant`) — the edge maps that
/// to `404`, exactly as the prediction read surface maps `prediction.not_found`.
///
/// Never throws; returns a typed [Result].
final class GetCompetition {
  /// Creates the use-case over its repository.
  const GetCompetition({required CompetitionRepository repository})
    : _competition = repository;

  final CompetitionRepository _competition;

  /// Reads the competition [competitionId], visible to [principal].
  Future<Result<Competition>> call({
    required AuthenticatedUser principal,
    required String competitionId,
  }) async {
    final auth = Authorization.requireRole(principal, PlatformRole.user);
    if (auth is Err<AuthenticatedUser>) {
      return Result.err(auth.error);
    }

    final idResult = CompetitionId.tryParse(competitionId);
    if (idResult is Err<CompetitionId>) {
      return Result.err(idResult.error);
    }

    return _competition.findCompetition((idResult as Ok<CompetitionId>).value);
  }
}
