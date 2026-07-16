import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

const _roundId = '11111111-1111-1111-1111-111111111111';
const _seasonId = '22222222-2222-2222-2222-222222222222';

RulesetSnapshot _snapshot() =>
    (RulesetSnapshot.create(payload: const {'points': 5}, rulesetVersion: 1)
            as Ok<RulesetSnapshot>)
        .value;

Round _openRound({
  int sequence = 1,
  DateTime? deadline,
  RulesetSnapshot? ruleset,
}) {
  final result = Round.open(
    id: const RoundId(_roundId),
    seasonId: const SeasonId(_seasonId),
    sequence: sequence,
    predictionDeadline: deadline ?? DateTime.utc(2026, 8, 1, 12),
    ruleset: ruleset ?? _snapshot(),
  );
  return (result as Ok<Round>).value;
}

void main() {
  group('Round.open', () {
    test('is born open with the ruleset already frozen', () {
      final round = _openRound();
      expect(round.status, RoundStatus.open);
      expect(round.status.isOpen, isTrue);
      expect(round.ruleset, _snapshot());
      expect(round.sequence, 1);
    });

    test('rejects a non-positive sequence', () {
      final result = Round.open(
        id: const RoundId(_roundId),
        seasonId: const SeasonId(_seasonId),
        sequence: 0,
        predictionDeadline: DateTime.utc(2026, 8, 1),
        ruleset: _snapshot(),
      );
      final error = (result as Err<Round>).error;
      expect(error.kind, ErrorKind.validation);
      expect(error.code, 'competition.round_sequence_invalid');
    });

    test('rejects a non-UTC prediction deadline', () {
      final result = Round.open(
        id: const RoundId(_roundId),
        seasonId: const SeasonId(_seasonId),
        sequence: 1,
        // Local (non-UTC) instant must be rejected.
        predictionDeadline: DateTime(2026, 8, 1, 12),
        ruleset: _snapshot(),
      );
      final error = (result as Err<Round>).error;
      expect(error.kind, ErrorKind.validation);
      expect(error.code, 'competition.round_deadline_not_utc');
    });
  });

  group('Round.transitionTo — linear lifecycle', () {
    test('open -> locked is permitted and carries the ruleset unchanged', () {
      final round = _openRound();
      final result = round.transitionTo(RoundStatus.locked);
      final locked = (result as Ok<Round>).value;
      expect(locked.status, RoundStatus.locked);
      expect(locked.ruleset, round.ruleset); // freeze preserved
      expect(locked.id, round.id);
      expect(locked.sequence, round.sequence);
    });

    test('locked -> scored is permitted', () {
      final locked =
          (_openRound().transitionTo(RoundStatus.locked) as Ok<Round>).value;
      final result = locked.transitionTo(RoundStatus.scored);
      expect((result as Ok<Round>).value.status, RoundStatus.scored);
    });

    test('open -> scored (skipping) is an invariant violation', () {
      final result = _openRound().transitionTo(RoundStatus.scored);
      final error = (result as Err<Round>).error;
      expect(error.kind, ErrorKind.invariant);
      expect(error.code, 'competition.round_illegal_transition');
    });

    test('a backward transition (locked -> open) is rejected', () {
      final locked =
          (_openRound().transitionTo(RoundStatus.locked) as Ok<Round>).value;
      final result = locked.transitionTo(RoundStatus.open);
      expect((result as Err<Round>).error.kind, ErrorKind.invariant);
    });

    test('a no-op self-transition (open -> open) is rejected', () {
      final result = _openRound().transitionTo(RoundStatus.open);
      expect((result as Err<Round>).error.kind, ErrorKind.invariant);
    });

    test('scored is terminal — no transition out of it', () {
      final scored =
          (((_openRound().transitionTo(RoundStatus.locked) as Ok<Round>).value
                      .transitionTo(RoundStatus.scored))
                  as Ok<Round>)
              .value;
      expect(scored.transitionTo(RoundStatus.locked).isErr, isTrue);
      expect(scored.transitionTo(RoundStatus.scored).isErr, isTrue);
    });
  });

  group('Round equality', () {
    test('identical rounds compare equal', () {
      expect(_openRound(), _openRound());
      expect(_openRound().hashCode, _openRound().hashCode);
    });

    test('differing status breaks equality', () {
      final locked =
          (_openRound().transitionTo(RoundStatus.locked) as Ok<Round>).value;
      expect(_openRound(), isNot(locked));
    });
  });
}
