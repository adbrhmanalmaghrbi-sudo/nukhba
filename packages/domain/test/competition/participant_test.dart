import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

const _participantId = '11111111-1111-1111-1111-111111111111';
const _seasonId = '22222222-2222-2222-2222-222222222222';
const _userId = '33333333-3333-3333-3333-333333333333';

Participant _joined({DateTime? at}) {
  final result = Participant.join(
    id: const ParticipantId(_participantId),
    seasonId: const SeasonId(_seasonId),
    userId: const UserId(_userId),
    joinedAt: at ?? DateTime.utc(2026, 8, 1, 12),
  );
  return (result as Ok<Participant>).value;
}

void main() {
  group('Participant.join', () {
    test('enrols a user as active', () {
      final participant = _joined();
      expect(participant.status, ParticipantStatus.active);
      expect(participant.status.isActive, isTrue);
      expect(participant.seasonId, const SeasonId(_seasonId));
      expect(participant.userId, const UserId(_userId));
      expect(participant.joinedAt, DateTime.utc(2026, 8, 1, 12));
    });

    test('rejects a non-UTC joinedAt', () {
      final result = Participant.join(
        id: const ParticipantId(_participantId),
        seasonId: const SeasonId(_seasonId),
        userId: const UserId(_userId),
        joinedAt: DateTime(2026, 8, 1, 12), // local
      );
      final error = (result as Err<Participant>).error;
      expect(error.kind, ErrorKind.validation);
      expect(error.code, 'competition.participant_joined_at_not_utc');
    });
  });

  group('Participant.withdraw', () {
    test('produces a withdrawn copy preserving identity/joinedAt', () {
      final participant = _joined();
      final result = participant.withdraw();
      final withdrawn = (result as Ok<Participant>).value;
      expect(withdrawn.status, ParticipantStatus.withdrawn);
      expect(withdrawn.id, participant.id);
      expect(withdrawn.seasonId, participant.seasonId);
      expect(withdrawn.userId, participant.userId);
      expect(withdrawn.joinedAt, participant.joinedAt);
    });

    test(
      'withdrawing an already-withdrawn participant is an invariant error',
      () {
        final withdrawn = (_joined().withdraw() as Ok<Participant>).value;
        final result = withdrawn.withdraw();
        final error = (result as Err<Participant>).error;
        expect(error.kind, ErrorKind.invariant);
        expect(error.code, 'competition.participant_already_withdrawn');
      },
    );
  });

  group('Participant equality', () {
    test('identical participants compare equal', () {
      expect(_joined(), _joined());
      expect(_joined().hashCode, _joined().hashCode);
    });

    test('differing status breaks equality', () {
      final withdrawn = (_joined().withdraw() as Ok<Participant>).value;
      expect(_joined(), isNot(withdrawn));
    });
  });
}
