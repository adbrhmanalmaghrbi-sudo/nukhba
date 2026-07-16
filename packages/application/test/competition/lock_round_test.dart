import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import 'fake_competition_repository.dart';
import 'fakes.dart';

const _adminId = '11111111-1111-1111-1111-111111111111';
const _seasonId = '22222222-2222-2222-2222-222222222222';
const _roundId = '33333333-3333-3333-3333-333333333333';

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
  final locked = (open.transitionTo(RoundStatus.locked) as Ok<Round>).value;
  if (status == RoundStatus.locked) return locked;
  return (locked.transitionTo(RoundStatus.scored) as Ok<Round>).value;
}

void main() {
  late FakeCompetitionRepository repo;
  late LockRound useCase;

  setUp(() {
    repo = FakeCompetitionRepository();
    useCase = LockRound(repo);
  });

  test('admin locks an open round; the ruleset is carried through', () async {
    repo.seedRound(_round());

    final result = await useCase(
      principal: adminPrincipal(_adminId),
      roundId: _roundId,
    );

    final locked = (result as Ok<Round>).value;
    expect(locked.status, RoundStatus.locked);
    expect(locked.ruleset, _round().ruleset); // freeze untouched
    // The stored round now reflects the locked status (guarded update applied).
    expect(repo.round(_roundId)!.status, RoundStatus.locked);
  });

  test('non-admin is rejected', () async {
    repo.seedRound(_round());
    final result = await useCase(
      principal: userPrincipal(_adminId),
      roundId: _roundId,
    );
    expect((result as Err<Round>).error.kind, ErrorKind.authorization);
  });

  test('a missing round is an invariant precondition failure', () async {
    final result = await useCase(
      principal: adminPrincipal(_adminId),
      roundId: _roundId,
    );
    expect((result as Err<Round>).error.code, 'competition.round_not_found');
  });

  test(
    'locking an already-locked round is an illegal-transition invariant',
    () async {
      repo.seedRound(_round(status: RoundStatus.locked));
      final result = await useCase(
        principal: adminPrincipal(_adminId),
        roundId: _roundId,
      );
      final error = (result as Err<Round>).error;
      expect(error.kind, ErrorKind.invariant);
      expect(error.code, 'competition.round_illegal_transition');
    },
  );

  test('a malformed round id is a validation error', () async {
    final result = await useCase(
      principal: adminPrincipal(_adminId),
      roundId: 'x',
    );
    expect((result as Err<Round>).error.code, 'competition.round_id_malformed');
  });
}
