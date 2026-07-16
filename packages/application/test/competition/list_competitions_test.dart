import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import 'fake_competition_repository.dart';
import 'fakes.dart';

const _user = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee';
const _service = 'ffffffff-ffff-ffff-ffff-ffffffffffff';

const _c1 = '11111111-1111-1111-1111-111111111111';
const _c2 = '22222222-2222-2222-2222-222222222222';
const _c3 = '33333333-3333-3333-3333-333333333333';

Competition _competition({
  required String id,
  required String name,
  required CompetitionVisibility visibility,
}) => Competition.fromStored(
  id: CompetitionId(id),
  name: name,
  format: FormatType.footballScoreline,
  visibility: visibility,
);

AuthenticatedUser _servicePrincipal(String userId) =>
    AuthenticatedUser(userId: UserId(userId), role: PlatformRole.service);

void main() {
  late FakeCompetitionRepository repo;
  late ListCompetitions useCase;

  setUp(() {
    repo = FakeCompetitionRepository();
    useCase = ListCompetitions(repository: repo);
  });

  test(
    'an authenticated user lists the public catalogue, name-ordered',
    () async {
      // Seeded out of order to prove the read imposes the ordering.
      repo.seedCompetition(
        _competition(
          id: _c2,
          name: 'Bundesliga Predictions',
          visibility: CompetitionVisibility.public,
        ),
      );
      repo.seedCompetition(
        _competition(
          id: _c1,
          name: 'Al-Nukhba Cup',
          visibility: CompetitionVisibility.public,
        ),
      );

      final r = await useCase.call(principal: userPrincipal(_user));

      final list = (r as Ok<List<Competition>>).value;
      expect(list.map((c) => c.name).toList(), [
        'Al-Nukhba Cup',
        'Bundesliga Predictions',
      ]);
    },
  );

  test(
    'private competitions are excluded from the browsable catalogue',
    () async {
      repo.seedCompetition(
        _competition(
          id: _c1,
          name: 'Public League',
          visibility: CompetitionVisibility.public,
        ),
      );
      repo.seedCompetition(
        _competition(
          id: _c2,
          name: 'Secret League',
          visibility: CompetitionVisibility.private,
        ),
      );

      final r = await useCase.call(principal: userPrincipal(_user));

      final list = (r as Ok<List<Competition>>).value;
      expect(list.map((c) => c.id.value).toList(), [_c1]);
    },
  );

  test('ties on name are broken by id for a stable order', () async {
    repo.seedCompetition(
      _competition(
        id: _c3,
        name: 'League',
        visibility: CompetitionVisibility.public,
      ),
    );
    repo.seedCompetition(
      _competition(
        id: _c1,
        name: 'League',
        visibility: CompetitionVisibility.public,
      ),
    );

    final r = await useCase.call(principal: userPrincipal(_user));

    final list = (r as Ok<List<Competition>>).value;
    expect(list.map((c) => c.id.value).toList(), [_c1, _c3]);
  });

  test('an empty catalogue is a legitimate empty list, not an error', () async {
    final r = await useCase.call(principal: userPrincipal(_user));
    expect((r as Ok<List<Competition>>).value, isEmpty);
  });

  test('a higher-privileged principal (service) is also authorized', () async {
    repo.seedCompetition(
      _competition(
        id: _c1,
        name: 'League',
        visibility: CompetitionVisibility.public,
      ),
    );

    final r = await useCase.call(principal: _servicePrincipal(_service));

    expect(r, isA<Ok<List<Competition>>>());
    expect((r as Ok<List<Competition>>).value, hasLength(1));
  });

  test('a transient repository failure is propagated unchanged', () async {
    repo.failNextWith(
      const AppError.transient('db.unavailable', 'connection reset'),
    );

    final r = await useCase.call(principal: userPrincipal(_user));

    final err = (r as Err<List<Competition>>).error;
    expect(err.kind, ErrorKind.transient);
    expect(err.code, 'db.unavailable');
  });
}
