import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

const _validUuid = '11111111-2222-3333-4444-555555555555';

void main() {
  group('Competition-aggregate id tryParse', () {
    test('CompetitionId parses a valid UUID and is a distinct type', () {
      final result = CompetitionId.tryParse(_validUuid);
      expect((result as Ok<CompetitionId>).value.value, _validUuid);
    });

    test('CompetitionId rejects null/empty/non-UUID', () {
      expect(
        (CompetitionId.tryParse(null) as Err<CompetitionId>).error.code,
        'competition.competition_id_empty',
      );
      expect(
        (CompetitionId.tryParse('') as Err<CompetitionId>).error.code,
        'competition.competition_id_empty',
      );
      expect(
        (CompetitionId.tryParse('not-a-uuid') as Err<CompetitionId>).error.code,
        'competition.competition_id_malformed',
      );
    });

    test(
      'SeasonId / RoundId / ParticipantId / FixtureRef parse valid UUIDs',
      () {
        expect(SeasonId.tryParse(_validUuid).isOk, isTrue);
        expect(RoundId.tryParse(_validUuid).isOk, isTrue);
        expect(ParticipantId.tryParse(_validUuid).isOk, isTrue);
        expect(FixtureRef.tryParse(_validUuid).isOk, isTrue);
      },
    );

    test('malformed values are rejected with the type-specific code', () {
      expect(
        (SeasonId.tryParse('x') as Err<SeasonId>).error.code,
        'competition.season_id_malformed',
      );
      expect(
        (RoundId.tryParse('x') as Err<RoundId>).error.code,
        'competition.round_id_malformed',
      );
      expect(
        (ParticipantId.tryParse('x') as Err<ParticipantId>).error.code,
        'competition.participant_id_malformed',
      );
      expect(
        (FixtureRef.tryParse('x') as Err<FixtureRef>).error.code,
        'competition.fixture_ref_malformed',
      );
    });

    test('distinct id types with the same value are not equal', () {
      const a = CompetitionId(_validUuid);
      const b = SeasonId(_validUuid);
      expect(a, isNot(b));
    });
  });

  group('FormatType', () {
    test('wireValue round-trips through tryParse', () {
      for (final value in FormatType.values) {
        final parsed = FormatType.tryParse(value.wireValue);
        expect((parsed as Ok<FormatType>).value, value);
      }
    });

    test('football_scoreline maps to the founding format', () {
      expect(FormatType.footballScoreline.wireValue, 'football_scoreline');
    });

    test('an unknown token is a validation error', () {
      final result = FormatType.tryParse('cricket');
      expect(
        (result as Err<FormatType>).error.code,
        'competition.format_type_unknown',
      );
    });

    test('null is not defaulted', () {
      expect(FormatType.tryParse(null).isErr, isTrue);
    });
  });

  group('CompetitionVisibility', () {
    test('wireValue round-trips', () {
      for (final value in CompetitionVisibility.values) {
        expect(
          (CompetitionVisibility.tryParse(value.wireValue)
                  as Ok<CompetitionVisibility>)
              .value,
          value,
        );
      }
    });

    test('unknown token rejected', () {
      expect(
        (CompetitionVisibility.tryParse('secret') as Err<CompetitionVisibility>)
            .error
            .code,
        'competition.visibility_unknown',
      );
    });
  });

  group('RoundStatus', () {
    test('wireValue round-trips', () {
      for (final value in RoundStatus.values) {
        expect(
          (RoundStatus.tryParse(value.wireValue) as Ok<RoundStatus>).value,
          value,
        );
      }
    });

    test('isOpen only for open', () {
      expect(RoundStatus.open.isOpen, isTrue);
      expect(RoundStatus.locked.isOpen, isFalse);
      expect(RoundStatus.scored.isOpen, isFalse);
    });

    test('canTransitionTo encodes the linear machine', () {
      expect(RoundStatus.open.canTransitionTo(RoundStatus.locked), isTrue);
      expect(RoundStatus.open.canTransitionTo(RoundStatus.scored), isFalse);
      expect(RoundStatus.open.canTransitionTo(RoundStatus.open), isFalse);
      expect(RoundStatus.locked.canTransitionTo(RoundStatus.scored), isTrue);
      expect(RoundStatus.locked.canTransitionTo(RoundStatus.open), isFalse);
      expect(RoundStatus.scored.canTransitionTo(RoundStatus.locked), isFalse);
    });

    test('unknown token rejected', () {
      expect(
        (RoundStatus.tryParse('paused') as Err<RoundStatus>).error.code,
        'competition.round_status_unknown',
      );
    });
  });

  group('ParticipantStatus', () {
    test('wireValue round-trips', () {
      for (final value in ParticipantStatus.values) {
        expect(
          (ParticipantStatus.tryParse(value.wireValue) as Ok<ParticipantStatus>)
              .value,
          value,
        );
      }
    });

    test('isActive only for active', () {
      expect(ParticipantStatus.active.isActive, isTrue);
      expect(ParticipantStatus.withdrawn.isActive, isFalse);
    });

    test('unknown token rejected', () {
      expect(
        (ParticipantStatus.tryParse('banned') as Err<ParticipantStatus>)
            .error
            .code,
        'competition.participant_status_unknown',
      );
    });
  });
}
