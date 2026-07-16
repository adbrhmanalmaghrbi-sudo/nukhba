import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import 'fake_competition_repository.dart';
import 'fakes.dart';

const _user = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee';
const _season = '55555555-5555-5555-5555-555555555555';
const _otherSeason = '66666666-6666-6666-6666-666666666666';

const _r1 = '11111111-1111-1111-1111-111111111111';
const _r2 = '22222222-2222-2222-2222-222222222222';
const _r3 = '33333333-3333-3333-3333-333333333333';

RulesetSnapshot _snapshot() =>
    (RulesetSnapshot.create(payload: const {'points': 5}, rulesetVersion: 1)
            as Ok<RulesetSnapshot>)
        .value;

Round _round({
  required String id,
  required String seasonId,
  required int sequence,
}) => Round.fromStored(
  id: RoundId(id),
  seasonId: SeasonId(seasonId),
  sequence: sequence,
  predictionDeadline: DateTime.utc(2026),
  status: RoundStatus.open,
  ruleset: _snapshot(),
);

void main() {
  late FakeCompetitionRepository repo;
  late ListSeasonRounds useCase;

  setUp(() {
    repo = FakeCompetitionRepository();
    useCase = ListSeasonRounds(repository: repo);
  });

  test(
    'an authenticated user lists a season\'s rounds in sequence order',
    () async {
      // Seeded out of order to prove the read imposes sequence ordering.
      repo.seedRound(_round(id: _r2, seasonId: _season, sequence: 2));
      repo.seedRound(_round(id: _r1, seasonId: _season, sequence: 1));
      repo.seedRound(_round(id: _r3, seasonId: _season, sequence: 3));

      final r = await useCase.call(
        principal: userPrincipal(_user),
        seasonId: _season,
      );

      final list = (r as Ok<List<Round>>).value;
      expect(list.map((x) => x.sequence).toList(), [1, 2, 3]);
      expect(list.map((x) => x.id.value).toList(), [_r1, _r2, _r3]);
    },
  );

  test('only the requested season\'s rounds are returned', () async {
    repo.seedRound(_round(id: _r1, seasonId: _season, sequence: 1));
    repo.seedRound(_round(id: _r2, seasonId: _otherSeason, sequence: 1));

    final r = await useCase.call(
      principal: userPrincipal(_user),
      seasonId: _season,
    );

    final list = (r as Ok<List<Round>>).value;
    expect(list.map((x) => x.id.value).toList(), [_r1]);
  });

  test(
    'an absent/empty season is a legitimate empty list, never not-found',
    () async {
      final r = await useCase.call(
        principal: userPrincipal(_user),
        seasonId: _season,
      );

      expect(r, isA<Ok<List<Round>>>());
      expect((r as Ok<List<Round>>).value, isEmpty);
    },
  );

  test('a malformed id is a validation error before any lookup', () async {
    final r = await useCase.call(
      principal: userPrincipal(_user),
      seasonId: 'not-a-uuid',
    );

    expect((r as Err<List<Round>>).error.kind, ErrorKind.validation);
  });

  test('a transient repository failure is propagated unchanged', () async {
    repo.failNextWith(
      const AppError.transient('db.unavailable', 'connection reset'),
    );

    final r = await useCase.call(
      principal: userPrincipal(_user),
      seasonId: _season,
    );

    final err = (r as Err<List<Round>>).error;
    expect(err.kind, ErrorKind.transient);
    expect(err.code, 'db.unavailable');
  });
}
