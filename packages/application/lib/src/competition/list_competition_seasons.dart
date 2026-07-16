import 'package:application/src/competition/ports/competition_repository.dart';
import 'package:application/src/identity/authorization.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// Query use-case: list a competition's seasons, ordered by label (Application
/// ADR, Section 2: query separated from command).
///
/// The first middle step of the browse navigation competition → season → round
/// → fixtures: having opened a competition, a client lists its seasons to pick
/// one before listing that season's rounds. Added under the FA-1 scope closure
/// (2026-07-13, project-context §4) as a strictly additive read over the
/// already-migrated `competition.seasons` table — no new domain rule, no side
/// effect.
///
/// This hop is genuinely required because the domain has NO "current/active
/// season" concept: `CompetitionSeason` carries no status field and there is no
/// invariant limiting a competition to one active season at a time (verified
/// against `packages/domain/competition/` — the only `active` concept there is
/// `ParticipantStatus.active`). A multi-season competition must therefore be
/// browsed season-by-season.
///
/// The caller must be an authenticated user (`PlatformRole.user`, matching
/// every other client-facing read). A competition with no seasons — or one that
/// does not exist — yields a legitimate empty list (a browse read reveals no
/// existence oracle), never an error.
///
/// Never throws; returns a typed [Result].
final class ListCompetitionSeasons {
  /// Creates the use-case over its repository.
  const ListCompetitionSeasons({required CompetitionRepository repository})
    : _competition = repository;

  final CompetitionRepository _competition;

  /// Lists the seasons of the competition [competitionId], visible to
  /// [principal], ordered by their display label.
  Future<Result<List<CompetitionSeason>>> call({
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

    return _competition.listCompetitionSeasons(
      (idResult as Ok<CompetitionId>).value,
    );
  }
}
