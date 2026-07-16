import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import 'fake_competition_repository.dart';
import 'fakes.dart';

const _adminId = '11111111-1111-1111-1111-111111111111';
const _seasonId = '22222222-2222-2222-2222-222222222222';
const _roundId = '33333333-3333-3333-3333-333333333333';
const _fixtureId = '44444444-4444-4444-4444-444444444444';

Round _round({RoundStatus status = RoundStatus.open}) {
  final open =
      (Round.open(
                id: const RoundId(_roundId),
                seasonId: const SeasonId(_seasonId),
                sequence: 1,
                predictionDeadline: DateTime.utc(2026, 8, 1),
                ruleset: testSnapshot(),
              )
              as Ok<Round>)
          .value;
  if (status == RoundStatus.open) return open;
  return (open.transitionTo(RoundStatus.locked) as Ok<Round>).value;
}

void main() {
  late FakeCompetitionRepository repo;
  late LinkFixtureToRound useCase;

  setUp(() {
    repo = FakeCompetitionRepository();
    useCase = LinkFixtureToRound(repo);
  });

  test('admin links a fixture to an open round', () async {
    repo.seedRound(_round());

    final result = await useCase(
      principal: adminPrincipal(_adminId),
      roundId: _roundId,
      fixtureId: _fixtureId,
      displayOrder: 0,
    );

    final link = (result as Ok<RoundFixture>).value;
    expect(link.roundId, const RoundId(_roundId));
    expect(link.fixture, const FixtureRef(_fixtureId));
    expect(link.displayOrder, 0);
    expect(repo.roundFixtureCount, 1);
  });

  test('non-admin is rejected', () async {
    repo.seedRound(_round());
    final result = await useCase(
      principal: userPrincipal(_adminId),
      roundId: _roundId,
      fixtureId: _fixtureId,
      displayOrder: 0,
    );
    expect((result as Err<RoundFixture>).error.kind, ErrorKind.authorization);
  });

  test('linking to a locked round is rejected (composition frozen)', () async {
    repo.seedRound(_round(status: RoundStatus.locked));
    final result = await useCase(
      principal: adminPrincipal(_adminId),
      roundId: _roundId,
      fixtureId: _fixtureId,
      displayOrder: 0,
    );
    final error = (result as Err<RoundFixture>).error;
    expect(error.kind, ErrorKind.invariant);
    expect(error.code, 'competition.round_not_open_for_linking');
  });

  test('a missing round is an invariant precondition failure', () async {
    final result = await useCase(
      principal: adminPrincipal(_adminId),
      roundId: _roundId,
      fixtureId: _fixtureId,
      displayOrder: 0,
    );
    expect(
      (result as Err<RoundFixture>).error.code,
      'competition.round_not_found',
    );
  });

  test('a malformed fixture id is a validation error', () async {
    repo.seedRound(_round());
    final result = await useCase(
      principal: adminPrincipal(_adminId),
      roundId: _roundId,
      fixtureId: 'x',
      displayOrder: 0,
    );
    expect(
      (result as Err<RoundFixture>).error.code,
      'competition.fixture_ref_malformed',
    );
  });

  test('a negative display order is rejected by the domain', () async {
    repo.seedRound(_round());
    final result = await useCase(
      principal: adminPrincipal(_adminId),
      roundId: _roundId,
      fixtureId: _fixtureId,
      displayOrder: -1,
    );
    expect(
      (result as Err<RoundFixture>).error.code,
      'competition.round_fixture_order_invalid',
    );
  });

  test('a duplicate link surfaces as an invariant conflict', () async {
    repo.seedRound(_round());
    await useCase(
      principal: adminPrincipal(_adminId),
      roundId: _roundId,
      fixtureId: _fixtureId,
      displayOrder: 0,
    );
    final again = await useCase(
      principal: adminPrincipal(_adminId),
      roundId: _roundId,
      fixtureId: _fixtureId,
      displayOrder: 1,
    );
    expect(
      (again as Err<RoundFixture>).error.code,
      'competition.fixture_already_linked',
    );
  });
}
