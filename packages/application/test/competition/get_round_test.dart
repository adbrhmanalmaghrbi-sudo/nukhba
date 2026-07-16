import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import 'fake_competition_repository.dart';
import 'fakes.dart';

const _user = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee';
const _round = '33333333-3333-3333-3333-333333333333';
const _season = '55555555-5555-5555-5555-555555555555';
const _absent = '99999999-9999-9999-9999-999999999999';

RulesetSnapshot _snapshot() =>
    (RulesetSnapshot.create(payload: const {'points': 5}, rulesetVersion: 1)
            as Ok<RulesetSnapshot>)
        .value;

Round _round0({RoundStatus status = RoundStatus.open}) => Round.fromStored(
  id: const RoundId(_round),
  seasonId: const SeasonId(_season),
  sequence: 1,
  predictionDeadline: DateTime.utc(2026),
  status: status,
  ruleset: _snapshot(),
);

void main() {
  late FakeCompetitionRepository repo;
  late GetRound useCase;

  setUp(() {
    repo = FakeCompetitionRepository();
    useCase = GetRound(repository: repo);
  });

  test('an authenticated user reads an existing round', () async {
    repo.seedRound(_round0(status: RoundStatus.locked));

    final r = await useCase.call(
      principal: userPrincipal(_user),
      roundId: _round,
    );

    final round = (r as Ok<Round>).value;
    expect(round.id, const RoundId(_round));
    expect(round.status, RoundStatus.locked);
  });

  test('a missing round surfaces the round-not-found invariant', () async {
    final r = await useCase.call(
      principal: userPrincipal(_user),
      roundId: _absent,
    );

    final err = (r as Err<Round>).error;
    expect(err.kind, ErrorKind.invariant);
    expect(err.code, 'competition.round_not_found');
  });

  test('a malformed id is a validation error before any lookup', () async {
    final r = await useCase.call(
      principal: userPrincipal(_user),
      roundId: 'not-a-uuid',
    );

    expect((r as Err<Round>).error.kind, ErrorKind.validation);
  });

  test('a transient repository failure is propagated unchanged', () async {
    repo.seedRound(_round0());
    repo.failNextWith(
      const AppError.transient('db.unavailable', 'connection reset'),
    );

    final r = await useCase.call(
      principal: userPrincipal(_user),
      roundId: _round,
    );

    final err = (r as Err<Round>).error;
    expect(err.kind, ErrorKind.transient);
    expect(err.code, 'db.unavailable');
  });
}
