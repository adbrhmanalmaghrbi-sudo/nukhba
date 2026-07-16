import 'package:application/src/competition/ports/competition_repository.dart';
import 'package:application/src/identity/authorization.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// Query use-case: read a single round by id (Application ADR, Section 2: query
/// separated from command).
///
/// The client renders a round (its status + prediction deadline) before showing
/// the prediction form; this is the read that makes that possible. Added under
/// BLOCKER FA-1 (2026-07-13) as a strictly additive read over the already-
/// migrated `competition.rounds` table — no new domain rule, no side effect.
///
/// The caller must be an authenticated user (`PlatformRole.user`, matching
/// every other client-facing read). Reuses the ratified
/// [CompetitionRepository.findRound], which surfaces a missing round as
/// `competition.round_not_found` (an `invariant`) — the edge maps that to `404`.
///
/// Never throws; returns a typed [Result].
final class GetRound {
  /// Creates the use-case over its repository.
  const GetRound({required CompetitionRepository repository})
    : _competition = repository;

  final CompetitionRepository _competition;

  /// Reads the round [roundId], visible to [principal].
  Future<Result<Round>> call({
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

    return _competition.findRound((idResult as Ok<RoundId>).value);
  }
}
