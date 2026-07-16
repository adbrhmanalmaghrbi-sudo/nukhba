import 'package:application/src/common/id_generator.dart';
import 'package:application/src/competition/ports/competition_repository.dart';
import 'package:application/src/identity/authorization.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// Use-case: start a new [CompetitionSeason] under an existing competition
/// (Application ADR, Section 2: command intent `StartSeason`).
///
/// Admin-only (first authorization layer). Business preconditions: the target
/// competition must exist (checked via the repository, surfaced as
/// [ErrorKind.invariant] `competition.not_found` if it does not) and the season
/// label must be valid (domain-checked in `CompetitionSeason.create`).
///
/// Never throws; returns a typed [Result].
final class StartSeason {
  /// Creates the use-case over its collaborators.
  const StartSeason({
    required CompetitionRepository repository,
    required IdGenerator idGenerator,
  }) : _repository = repository,
       _idGenerator = idGenerator;

  final CompetitionRepository _repository;
  final IdGenerator _idGenerator;

  /// Starts a season labelled [label] under competition [competitionId].
  Future<Result<CompetitionSeason>> call({
    required AuthenticatedUser principal,
    required String competitionId,
    required String label,
  }) async {
    final auth = Authorization.requireRole(principal, PlatformRole.admin);
    if (auth is Err<AuthenticatedUser>) {
      return Result.err(auth.error);
    }

    final competitionIdResult = CompetitionId.tryParse(competitionId);
    if (competitionIdResult is Err<CompetitionId>) {
      return Result.err(competitionIdResult.error);
    }
    final compId = (competitionIdResult as Ok<CompetitionId>).value;

    // Precondition: the competition must exist. Loading it (rather than blindly
    // inserting) gives a clear invariant error instead of an opaque FK failure.
    final competition = await _repository.findCompetition(compId);
    if (competition is Err<Competition>) {
      return Result.err(competition.error);
    }

    final seasonIdResult = SeasonId.tryParse(_idGenerator.newUuid());
    if (seasonIdResult is Err<SeasonId>) {
      return Result.err(seasonIdResult.error);
    }

    final seasonResult = CompetitionSeason.create(
      id: (seasonIdResult as Ok<SeasonId>).value,
      competitionId: compId,
      label: label,
    );
    if (seasonResult is Err<CompetitionSeason>) {
      return Result.err(seasonResult.error);
    }
    final season = (seasonResult as Ok<CompetitionSeason>).value;

    final saved = await _repository.saveSeason(season);
    return switch (saved) {
      Ok<void>() => Result.ok(season),
      Err<void>(:final error) => Result.err(error),
    };
  }
}
