import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import 'fake_competition_repository.dart';
import 'fakes.dart';

const _user = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee';
const _round = '33333333-3333-3333-3333-333333333333';
const _otherRound = '44444444-4444-4444-4444-444444444444';

const _fa = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
const _fb = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
const _fc = 'cccccccc-cccc-cccc-cccc-cccccccccccc';

RoundFixture _link({
  required String roundId,
  required String fixtureId,
  required int order,
}) => RoundFixture.fromStored(
  roundId: RoundId(roundId),
  fixture: FixtureRef(fixtureId),
  displayOrder: order,
);

void main() {
  late FakeCompetitionRepository repo;
  late ListRoundFixtures useCase;

  setUp(() {
    repo = FakeCompetitionRepository();
    useCase = ListRoundFixtures(repository: repo);
  });

  Future<void> seed(RoundFixture link) async {
    final r = await repo.saveRoundFixture(link);
    expect(r.isOk, isTrue);
  }

  test(
    'an authenticated user lists a round\'s fixtures in display order',
    () async {
      // Saved out of order to prove the read imposes display_order ordering.
      await seed(_link(roundId: _round, fixtureId: _fb, order: 1));
      await seed(_link(roundId: _round, fixtureId: _fa, order: 0));
      await seed(_link(roundId: _round, fixtureId: _fc, order: 2));

      final r = await useCase.call(
        principal: userPrincipal(_user),
        roundId: _round,
      );

      final list = (r as Ok<List<RoundFixture>>).value;
      expect(list.map((x) => x.displayOrder).toList(), [0, 1, 2]);
      expect(list.map((x) => x.fixture.value).toList(), [_fa, _fb, _fc]);
    },
  );

  test('ties on display order are broken by fixture id', () async {
    await seed(_link(roundId: _round, fixtureId: _fc, order: 0));
    await seed(_link(roundId: _round, fixtureId: _fa, order: 0));

    final r = await useCase.call(
      principal: userPrincipal(_user),
      roundId: _round,
    );

    final list = (r as Ok<List<RoundFixture>>).value;
    expect(list.map((x) => x.fixture.value).toList(), [_fa, _fc]);
  });

  test('only the requested round\'s fixtures are returned', () async {
    await seed(_link(roundId: _round, fixtureId: _fa, order: 0));
    await seed(_link(roundId: _otherRound, fixtureId: _fb, order: 0));

    final r = await useCase.call(
      principal: userPrincipal(_user),
      roundId: _round,
    );

    final list = (r as Ok<List<RoundFixture>>).value;
    expect(list.map((x) => x.fixture.value).toList(), [_fa]);
  });

  test(
    'an absent/empty round is a legitimate empty list, never not-found',
    () async {
      final r = await useCase.call(
        principal: userPrincipal(_user),
        roundId: _round,
      );

      expect(r, isA<Ok<List<RoundFixture>>>());
      expect((r as Ok<List<RoundFixture>>).value, isEmpty);
    },
  );

  test('a malformed id is a validation error before any lookup', () async {
    final r = await useCase.call(
      principal: userPrincipal(_user),
      roundId: 'not-a-uuid',
    );

    expect((r as Err<List<RoundFixture>>).error.kind, ErrorKind.validation);
  });

  test('a transient repository failure is propagated unchanged', () async {
    repo.failNextWith(
      const AppError.transient('db.unavailable', 'connection reset'),
    );

    final r = await useCase.call(
      principal: userPrincipal(_user),
      roundId: _round,
    );

    final err = (r as Err<List<RoundFixture>>).error;
    expect(err.kind, ErrorKind.transient);
    expect(err.code, 'db.unavailable');
  });
}
