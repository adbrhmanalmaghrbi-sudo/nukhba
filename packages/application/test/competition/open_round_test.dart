import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import 'fake_competition_repository.dart';
import 'fakes.dart';

const _adminId = '11111111-1111-1111-1111-111111111111';
const _competitionId = '22222222-2222-2222-2222-222222222222';
const _seasonId = '33333333-3333-3333-3333-333333333333';
const _newRoundId = '44444444-4444-4444-4444-444444444444';

Competition _competition() =>
    (Competition.create(
              id: const CompetitionId(_competitionId),
              name: 'Comp',
              format: FormatType.footballScoreline,
              visibility: CompetitionVisibility.public,
            )
            as Ok<Competition>)
        .value;

CompetitionSeason _season() =>
    (CompetitionSeason.create(
              id: const SeasonId(_seasonId),
              competitionId: const CompetitionId(_competitionId),
              label: '2026/27',
            )
            as Ok<CompetitionSeason>)
        .value;

void main() {
  late FakeCompetitionRepository repo;
  late FakeRulesetProvider ruleset;
  late OpenRound useCase;

  final deadline = DateTime.utc(2026, 8, 1, 12);

  setUp(() {
    repo = FakeCompetitionRepository();
    ruleset = FakeRulesetProvider(Result.ok(testSnapshot(version: 7)));
    useCase = OpenRound(
      repository: repo,
      rulesetProvider: ruleset,
      idGenerator: FakeIdGenerator([_newRoundId]),
    );
  });

  test('admin opens a round with the ruleset frozen at open time', () async {
    repo.seedCompetition(_competition());
    repo.seedSeason(_season());

    final result = await useCase(
      principal: adminPrincipal(_adminId),
      seasonId: _seasonId,
      sequence: 1,
      predictionDeadline: deadline,
    );

    final round = (result as Ok<Round>).value;
    expect(round.id, const RoundId(_newRoundId));
    expect(round.status, RoundStatus.open);
    expect(round.sequence, 1);
    expect(round.ruleset.rulesetVersion, 7); // frozen from the provider
    // The provider was asked for the *competition's* format.
    expect(ruleset.lastFormat, FormatType.footballScoreline);
  });

  test('non-admin is rejected', () async {
    repo.seedCompetition(_competition());
    repo.seedSeason(_season());
    final result = await useCase(
      principal: userPrincipal(_adminId),
      seasonId: _seasonId,
      sequence: 1,
      predictionDeadline: deadline,
    );
    expect((result as Err<Round>).error.kind, ErrorKind.authorization);
  });

  test('a missing season is an invariant precondition failure', () async {
    final result = await useCase(
      principal: adminPrincipal(_adminId),
      seasonId: _seasonId,
      sequence: 1,
      predictionDeadline: deadline,
    );
    expect((result as Err<Round>).error.code, 'competition.season_not_found');
  });

  test('a missing parent competition is an invariant failure', () async {
    // Season exists but its competition was never seeded.
    repo.seedSeason(_season());
    final result = await useCase(
      principal: adminPrincipal(_adminId),
      seasonId: _seasonId,
      sequence: 1,
      predictionDeadline: deadline,
    );
    expect((result as Err<Round>).error.code, 'competition.not_found');
  });

  test('a ruleset-provider failure short-circuits opening the round', () async {
    repo.seedCompetition(_competition());
    repo.seedSeason(_season());
    ruleset = FakeRulesetProvider(
      const Result.err(AppError.invariant('scoring.no_ruleset', 'none')),
    );
    useCase = OpenRound(
      repository: repo,
      rulesetProvider: ruleset,
      idGenerator: FakeIdGenerator([_newRoundId]),
    );

    final result = await useCase(
      principal: adminPrincipal(_adminId),
      seasonId: _seasonId,
      sequence: 1,
      predictionDeadline: deadline,
    );
    expect((result as Err<Round>).error.code, 'scoring.no_ruleset');
    // No round persisted when the ruleset cannot be resolved.
    expect((await repo.findRound(const RoundId(_newRoundId))).isErr, isTrue);
  });

  test('a non-UTC deadline is rejected by the domain', () async {
    repo.seedCompetition(_competition());
    repo.seedSeason(_season());
    final result = await useCase(
      principal: adminPrincipal(_adminId),
      seasonId: _seasonId,
      sequence: 1,
      predictionDeadline: DateTime(2026, 8, 1, 12), // local
    );
    expect(
      (result as Err<Round>).error.code,
      'competition.round_deadline_not_utc',
    );
  });

  test(
    'a duplicate sequence within a season surfaces as an invariant conflict',
    () async {
      repo.seedCompetition(_competition());
      repo.seedSeason(_season());
      // Seed an existing round #1.
      repo.seedRound(
        (Round.open(
                  id: const RoundId('55555555-5555-5555-5555-555555555555'),
                  seasonId: const SeasonId(_seasonId),
                  sequence: 1,
                  predictionDeadline: deadline,
                  ruleset: testSnapshot(),
                )
                as Ok<Round>)
            .value,
      );

      final result = await useCase(
        principal: adminPrincipal(_adminId),
        seasonId: _seasonId,
        sequence: 1, // clashes
        predictionDeadline: deadline,
      );
      expect(
        (result as Err<Round>).error.code,
        'competition.round_sequence_conflict',
      );
    },
  );
}
