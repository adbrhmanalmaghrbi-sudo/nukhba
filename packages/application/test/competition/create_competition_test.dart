import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import 'fake_competition_repository.dart';
import 'fakes.dart';

const _adminId = '11111111-1111-1111-1111-111111111111';
const _newId = '22222222-2222-2222-2222-222222222222';

void main() {
  late FakeCompetitionRepository repo;
  late CreateCompetition useCase;

  setUp(() {
    repo = FakeCompetitionRepository();
    useCase = CreateCompetition(
      repository: repo,
      idGenerator: FakeIdGenerator([_newId]),
    );
  });

  test('admin creates a competition and it is persisted', () async {
    final result = await useCase(
      principal: adminPrincipal(_adminId),
      name: 'Premier Predictions',
      format: 'football_scoreline',
      visibility: 'public',
    );

    final competition = (result as Ok<Competition>).value;
    expect(competition.id, const CompetitionId(_newId));
    expect(competition.name, 'Premier Predictions');
    expect(competition.format, FormatType.footballScoreline);
    // It is actually stored (a subsequent find succeeds).
    final found = await repo.findCompetition(const CompetitionId(_newId));
    expect(found.isOk, isTrue);
  });

  test(
    'a non-admin (plain user) is rejected with an authorization error',
    () async {
      final result = await useCase(
        principal: userPrincipal(_adminId),
        name: 'X',
        format: 'football_scoreline',
        visibility: 'public',
      );
      expect((result as Err<Competition>).error.kind, ErrorKind.authorization);
    },
  );

  test('an unknown format token is a validation error', () async {
    final result = await useCase(
      principal: adminPrincipal(_adminId),
      name: 'X',
      format: 'cricket',
      visibility: 'public',
    );
    expect(
      (result as Err<Competition>).error.code,
      'competition.format_type_unknown',
    );
  });

  test('an unknown visibility token is a validation error', () async {
    final result = await useCase(
      principal: adminPrincipal(_adminId),
      name: 'X',
      format: 'football_scoreline',
      visibility: 'secret',
    );
    expect(
      (result as Err<Competition>).error.code,
      'competition.visibility_unknown',
    );
  });

  test('an empty name is rejected by the domain', () async {
    final result = await useCase(
      principal: adminPrincipal(_adminId),
      name: '   ',
      format: 'football_scoreline',
      visibility: 'public',
    );
    expect((result as Err<Competition>).error.code, 'competition.name_empty');
  });

  test('a transient repository failure is propagated for retry', () async {
    repo.failNextWith(const AppError.transient('db.query_failed', 'boom'));
    final result = await useCase(
      principal: adminPrincipal(_adminId),
      name: 'X',
      format: 'football_scoreline',
      visibility: 'public',
    );
    expect((result as Err<Competition>).error.kind, ErrorKind.transient);
  });
}
