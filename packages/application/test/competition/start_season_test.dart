import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import 'fake_competition_repository.dart';
import 'fakes.dart';

const _adminId = '11111111-1111-1111-1111-111111111111';
const _competitionId = '22222222-2222-2222-2222-222222222222';
const _newSeasonId = '33333333-3333-3333-3333-333333333333';

Competition _competition() =>
    (Competition.create(
              id: const CompetitionId(_competitionId),
              name: 'Comp',
              format: FormatType.footballScoreline,
              visibility: CompetitionVisibility.public,
            )
            as Ok<Competition>)
        .value;

void main() {
  late FakeCompetitionRepository repo;
  late StartSeason useCase;

  setUp(() {
    repo = FakeCompetitionRepository();
    useCase = StartSeason(
      repository: repo,
      idGenerator: FakeIdGenerator([_newSeasonId]),
    );
  });

  test('admin starts a season under an existing competition', () async {
    repo.seedCompetition(_competition());

    final result = await useCase(
      principal: adminPrincipal(_adminId),
      competitionId: _competitionId,
      label: '2026/27',
    );

    final season = (result as Ok<CompetitionSeason>).value;
    expect(season.id, const SeasonId(_newSeasonId));
    expect(season.competitionId, const CompetitionId(_competitionId));
    expect(season.label, '2026/27');
    expect((await repo.findSeason(const SeasonId(_newSeasonId))).isOk, isTrue);
  });

  test('non-admin is rejected', () async {
    repo.seedCompetition(_competition());
    final result = await useCase(
      principal: userPrincipal(_adminId),
      competitionId: _competitionId,
      label: '2026/27',
    );
    expect(
      (result as Err<CompetitionSeason>).error.kind,
      ErrorKind.authorization,
    );
  });

  test('a malformed competition id is a validation error', () async {
    final result = await useCase(
      principal: adminPrincipal(_adminId),
      competitionId: 'not-a-uuid',
      label: '2026/27',
    );
    expect(
      (result as Err<CompetitionSeason>).error.code,
      'competition.competition_id_malformed',
    );
  });

  test(
    'a missing competition is an invariant (not_found) precondition failure',
    () async {
      // No competition seeded.
      final result = await useCase(
        principal: adminPrincipal(_adminId),
        competitionId: _competitionId,
        label: '2026/27',
      );
      final error = (result as Err<CompetitionSeason>).error;
      expect(error.kind, ErrorKind.invariant);
      expect(error.code, 'competition.not_found');
    },
  );

  test('an empty label is rejected by the domain', () async {
    repo.seedCompetition(_competition());
    final result = await useCase(
      principal: adminPrincipal(_adminId),
      competitionId: _competitionId,
      label: '  ',
    );
    expect(
      (result as Err<CompetitionSeason>).error.code,
      'competition.season_label_empty',
    );
  });
}
