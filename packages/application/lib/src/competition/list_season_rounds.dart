import 'package:application/src/competition/ports/competition_repository.dart';
import 'package:application/src/identity/authorization.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// Query use-case: list a season's rounds, ordered by sequence (Application
/// ADR, Section 2: query separated from command).
///
/// The middle step of the browse navigation competition → season → round →
/// fixtures: having opened a competition/season, a client lists its rounds to
/// choose one to predict. Added under BLOCKER FA-1 (2026-07-13) as a strictly
/// additive read over the already-migrated `competition.rounds` table — no new
/// domain rule, no side effect.
///
/// The caller must be an authenticated user (`PlatformRole.user`, matching
/// every other client-facing read). A season with no rounds — or one that does
/// not exist — yields a legitimate empty list (a browse read reveals no
/// existence oracle), never an error.
///
/// Never throws; returns a typed [Result].
final class ListSeasonRounds {
  /// Creates the use-case over its repository.
  const ListSeasonRounds({required CompetitionRepository repository})
    : _competition = repository;

  final CompetitionRepository _competition;

  /// Lists the rounds of the season [seasonId], visible to [principal],
  /// ordered by their 1-based sequence.
  Future<Result<List<Round>>> call({
    required AuthenticatedUser principal,
    required String seasonId,
  }) async {
    final auth = Authorization.requireRole(principal, PlatformRole.user);
    if (auth is Err<AuthenticatedUser>) {
      return Result.err(auth.error);
    }

    final idResult = SeasonId.tryParse(seasonId);
    if (idResult is Err<SeasonId>) {
      return Result.err(idResult.error);
    }

    return _competition.listSeasonRounds((idResult as Ok<SeasonId>).value);
  }
}
