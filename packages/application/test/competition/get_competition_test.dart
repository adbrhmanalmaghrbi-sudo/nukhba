import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import 'fake_competition_repository.dart';
import 'fakes.dart';

const _user = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee';
const _comp = '11111111-1111-1111-1111-111111111111';
const _absent = '99999999-9999-9999-9999-999999999999';

Competition _competition() => Competition.fromStored(
  id: const CompetitionId(_comp),
  name: 'Al-Nukhba Cup',
  format: FormatType.footballScoreline,
  visibility: CompetitionVisibility.public,
);

void main() {
  late FakeCompetitionRepository repo;
  late GetCompetition useCase;

  setUp(() {
    repo = FakeCompetitionRepository();
    useCase = GetCompetition(repository: repo);
  });

  test('an authenticated user reads an existing competition', () async {
    repo.seedCompetition(_competition());

    final r = await useCase.call(
      principal: userPrincipal(_user),
      competitionId: _comp,
    );

    final competition = (r as Ok<Competition>).value;
    expect(competition.id, const CompetitionId(_comp));
    expect(competition.name, 'Al-Nukhba Cup');
  });

  test('a missing competition surfaces the not-found invariant', () async {
    final r = await useCase.call(
      principal: userPrincipal(_user),
      competitionId: _absent,
    );

    final err = (r as Err<Competition>).error;
    expect(err.kind, ErrorKind.invariant);
    expect(err.code, 'competition.not_found');
  });

  test('a malformed id is a validation error before any lookup', () async {
    final r = await useCase.call(
      principal: userPrincipal(_user),
      competitionId: 'not-a-uuid',
    );

    expect((r as Err<Competition>).error.kind, ErrorKind.validation);
  });

  test('a transient repository failure is propagated unchanged', () async {
    repo.seedCompetition(_competition());
    repo.failNextWith(
      const AppError.transient('db.unavailable', 'connection reset'),
    );

    final r = await useCase.call(
      principal: userPrincipal(_user),
      competitionId: _comp,
    );

    final err = (r as Err<Competition>).error;
    expect(err.kind, ErrorKind.transient);
    expect(err.code, 'db.unavailable');
  });
}
