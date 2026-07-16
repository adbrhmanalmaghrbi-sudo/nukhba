import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import 'fake_competition_repository.dart';
import 'fakes.dart';

const _userId = '11111111-1111-1111-1111-111111111111';
const _competitionId = '22222222-2222-2222-2222-222222222222';
const _seasonId = '33333333-3333-3333-3333-333333333333';
const _participantId = '44444444-4444-4444-4444-444444444444';

final _now = DateTime.utc(2026, 8, 1, 12);

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
  late JoinCompetition useCase;

  setUp(() {
    repo = FakeCompetitionRepository();
    useCase = JoinCompetition(
      repository: repo,
      idGenerator: FakeIdGenerator([_participantId]),
      clock: FixedClock(_now),
    );
  });

  test(
    'any authenticated user joins as themselves (userId from token)',
    () async {
      repo.seedSeason(_season());

      final result = await useCase(
        principal: userPrincipal(_userId),
        seasonId: _seasonId,
      );

      final participant = (result as Ok<Participant>).value;
      expect(participant.id, const ParticipantId(_participantId));
      expect(participant.seasonId, const SeasonId(_seasonId));
      // Enrolled user is the verified principal, not any body-supplied value.
      expect(participant.userId, const UserId(_userId));
      expect(participant.status, ParticipantStatus.active);
      expect(participant.joinedAt, _now); // from the injected clock
    },
  );

  test(
    'joining is idempotent: a second join returns the existing enrolment',
    () async {
      repo.seedSeason(_season());

      final first = await useCase(
        principal: userPrincipal(_userId),
        seasonId: _seasonId,
      );
      final firstParticipant = (first as Ok<Participant>).value;

      // Second call: the id generator would yield a different id, but the
      // existing enrolment must be returned unchanged.
      final second = await useCase(
        principal: userPrincipal(_userId),
        seasonId: _seasonId,
      );
      final secondParticipant = (second as Ok<Participant>).value;

      expect(secondParticipant.id, firstParticipant.id);
      expect(secondParticipant, firstParticipant);
    },
  );

  test('a missing season is an invariant precondition failure', () async {
    final result = await useCase(
      principal: userPrincipal(_userId),
      seasonId: _seasonId,
    );
    expect(
      (result as Err<Participant>).error.code,
      'competition.season_not_found',
    );
  });

  test('a malformed season id is a validation error', () async {
    final result = await useCase(
      principal: userPrincipal(_userId),
      seasonId: 'x',
    );
    expect(
      (result as Err<Participant>).error.code,
      'competition.season_id_malformed',
    );
  });

  test(
    'a race-losing unique conflict converges by re-reading the winner',
    () async {
      repo.seedSeason(_season());
      // Simulate the "already there" winner having been written concurrently:
      // seed the participant so the save() hits the uniqueness guard, then the
      // use-case must re-read and return the winner idempotently.
      final winner =
          (Participant.join(
                    id: const ParticipantId(
                      '99999999-9999-9999-9999-999999999999',
                    ),
                    seasonId: const SeasonId(_seasonId),
                    userId: const UserId(_userId),
                    joinedAt: _now,
                  )
                  as Ok<Participant>)
              .value;

      // A repository whose findParticipant first reports "not joined" (so the
      // use-case proceeds to save) but whose save then conflicts.
      final racing = _RacingRepository(winner);
      racing.seedSeason(_season());
      final racingUseCase = JoinCompetition(
        repository: racing,
        idGenerator: FakeIdGenerator([_participantId]),
        clock: FixedClock(_now),
      );

      final result = await racingUseCase(
        principal: userPrincipal(_userId),
        seasonId: _seasonId,
      );

      expect((result as Ok<Participant>).value, winner);
    },
  );

  test('a transient season lookup failure is propagated', () async {
    repo.seedSeason(_season());
    repo.failNextWith(const AppError.transient('db.query_failed', 'boom'));
    final result = await useCase(
      principal: userPrincipal(_userId),
      seasonId: _seasonId,
    );
    expect((result as Err<Participant>).error.kind, ErrorKind.transient);
  });
}

/// A repository that reports "not joined" on the first `findParticipant`, then
/// fails `saveParticipant` with the unique-conflict error and finally, on the
/// re-read, returns the [_winner] — reproducing the concurrent-join race the
/// use-case's `_resolveConflict` handles.
final class _RacingRepository extends FakeCompetitionRepository {
  _RacingRepository(this._winner);
  final Participant _winner;
  int _finds = 0;

  @override
  Future<Result<Participant?>> findParticipant(
    SeasonId seasonId,
    UserId userId,
  ) async {
    _finds++;
    // First lookup (the idempotency pre-check): not joined yet.
    if (_finds == 1) return const Result.ok(null);
    // Re-read after the conflict: the winner is now visible.
    return Result.ok(_winner);
  }

  @override
  Future<Result<void>> saveParticipant(Participant participant) async {
    return const Result.err(
      AppError.invariant('competition.already_joined', 'already joined'),
    );
  }
}
