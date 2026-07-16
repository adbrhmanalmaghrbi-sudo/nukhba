import 'package:contracts/contracts.dart';
import 'package:test/test.dart';

void main() {
  group('CompetitionDto', () {
    test('round-trips through JSON', () {
      const dto = CompetitionDto(
        id: '11111111-1111-1111-1111-111111111111',
        name: 'Premier Predictions',
        format: 'football_scoreline',
        visibility: 'public',
      );
      final decoded = CompetitionDto.fromJson(dto.toJson());
      expect(decoded, dto);
      expect(decoded.schemaVersion, CompetitionDto.currentSchemaVersion);
    });

    test('defaults schema_version to 1 when absent (back-compat)', () {
      final decoded = CompetitionDto.fromJson(const {
        'id': 'x',
        'name': 'n',
        'format': 'football_scoreline',
        'visibility': 'private',
      });
      expect(decoded.schemaVersion, 1);
      expect(decoded.visibility, 'private');
    });

    test('toJson uses snake_case wire keys', () {
      const dto = CompetitionDto(
        id: 'i',
        name: 'n',
        format: 'football_scoreline',
        visibility: 'public',
      );
      final json = dto.toJson();
      expect(json.keys, containsAll(<String>['schema_version', 'id', 'name']));
    });
  });

  group('SeasonDto', () {
    test('round-trips through JSON', () {
      const dto = SeasonDto(
        id: '22222222-2222-2222-2222-222222222222',
        competitionId: '11111111-1111-1111-1111-111111111111',
        label: '2026/27',
      );
      final decoded = SeasonDto.fromJson(dto.toJson());
      expect(decoded, dto);
      expect(dto.toJson()['competition_id'], dto.competitionId);
    });
  });

  group('RoundDto', () {
    test('round-trips through JSON and excludes the ruleset payload', () {
      const dto = RoundDto(
        id: '33333333-3333-3333-3333-333333333333',
        seasonId: '22222222-2222-2222-2222-222222222222',
        sequence: 4,
        predictionDeadline: '2026-08-01T12:00:00.000Z',
        status: 'open',
        rulesetVersion: 1,
      );
      final json = dto.toJson();
      // Only the version crosses the wire — never the opaque snapshot payload.
      expect(json.containsKey('ruleset_snapshot'), isFalse);
      expect(json['ruleset_version'], 1);
      expect(RoundDto.fromJson(json), dto);
    });
  });

  group('ParticipantDto', () {
    test('round-trips through JSON', () {
      const dto = ParticipantDto(
        id: '44444444-4444-4444-4444-444444444444',
        seasonId: '22222222-2222-2222-2222-222222222222',
        userId: '55555555-5555-5555-5555-555555555555',
        status: 'active',
        joinedAt: '2026-08-01T12:00:00.000Z',
      );
      expect(ParticipantDto.fromJson(dto.toJson()), dto);
    });
  });

  group('RoundFixtureDto', () {
    test('round-trips through JSON', () {
      const dto = RoundFixtureDto(
        roundId: '33333333-3333-3333-3333-333333333333',
        fixtureId: '66666666-6666-6666-6666-666666666666',
        displayOrder: 0,
      );
      final decoded = RoundFixtureDto.fromJson(dto.toJson());
      expect(decoded, dto);
      expect(decoded.hashCode, dto.hashCode);
    });
  });
}
