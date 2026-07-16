import 'package:application/src/common/id_generator.dart';
import 'package:application/src/competition/ports/competition_repository.dart';
import 'package:application/src/competition/ports/ruleset_provider.dart';
import 'package:application/src/identity/authorization.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// Use-case: open a new [Round] in a season, freezing the ruleset onto it
/// (Application ADR, Section 2: command intent `OpenRound`; the founding
/// Competition-phase behaviour — Next-Task brief: "OpenRound freezes the ruleset
/// snapshot").
///
/// This is where the ruleset-freeze invariant is *established*: the use-case
/// asks the [RulesetProvider] for the current ruleset governing the competition's
/// [FormatType] at this instant, then constructs the round with that snapshot
/// already frozen (`Round.open` is born `open` with an immutable snapshot). No
/// later ruleset edit can reach back into this round — the snapshot is a copy,
/// not a reference.
///
/// Admin-only. Preconditions: the season exists, and (transitively) its
/// competition exists so the format can be resolved.
///
/// Never throws; returns a typed [Result].
final class OpenRound {
  /// Creates the use-case over its collaborators.
  const OpenRound({
    required CompetitionRepository repository,
    required RulesetProvider rulesetProvider,
    required IdGenerator idGenerator,
  }) : _repository = repository,
       _rulesetProvider = rulesetProvider,
       _idGenerator = idGenerator;

  final CompetitionRepository _repository;
  final RulesetProvider _rulesetProvider;
  final IdGenerator _idGenerator;

  /// Opens round [sequence] in season [seasonId] with prediction deadline
  /// [predictionDeadline] (must be UTC).
  Future<Result<Round>> call({
    required AuthenticatedUser principal,
    required String seasonId,
    required int sequence,
    required DateTime predictionDeadline,
  }) async {
    final auth = Authorization.requireRole(principal, PlatformRole.admin);
    if (auth is Err<AuthenticatedUser>) {
      return Result.err(auth.error);
    }

    final seasonIdResult = SeasonId.tryParse(seasonId);
    if (seasonIdResult is Err<SeasonId>) {
      return Result.err(seasonIdResult.error);
    }
    final sId = (seasonIdResult as Ok<SeasonId>).value;

    // Resolve the season, then its competition, so we know which format's
    // ruleset to freeze. Both must exist (invariant errors if not).
    final seasonResult = await _repository.findSeason(sId);
    if (seasonResult is Err<CompetitionSeason>) {
      return Result.err(seasonResult.error);
    }
    final season = (seasonResult as Ok<CompetitionSeason>).value;

    final competitionResult = await _repository.findCompetition(
      season.competitionId,
    );
    if (competitionResult is Err<Competition>) {
      return Result.err(competitionResult.error);
    }
    final competition = (competitionResult as Ok<Competition>).value;

    // Freeze the ruleset for this competition's format *now*.
    final snapshotResult = await _rulesetProvider.currentSnapshotFor(
      competition.format,
    );
    if (snapshotResult is Err<RulesetSnapshot>) {
      return Result.err(snapshotResult.error);
    }
    final snapshot = (snapshotResult as Ok<RulesetSnapshot>).value;

    final roundIdResult = RoundId.tryParse(_idGenerator.newUuid());
    if (roundIdResult is Err<RoundId>) {
      return Result.err(roundIdResult.error);
    }

    final roundResult = Round.open(
      id: (roundIdResult as Ok<RoundId>).value,
      seasonId: sId,
      sequence: sequence,
      predictionDeadline: predictionDeadline,
      ruleset: snapshot,
    );
    if (roundResult is Err<Round>) {
      return Result.err(roundResult.error);
    }
    final round = (roundResult as Ok<Round>).value;

    final saved = await _repository.saveRound(round);
    return switch (saved) {
      Ok<void>() => Result.ok(round),
      Err<void>(:final error) => Result.err(error),
    };
  }
}
