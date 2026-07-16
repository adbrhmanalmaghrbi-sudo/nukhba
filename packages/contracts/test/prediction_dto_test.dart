import 'package:contracts/contracts.dart';
import 'package:test/test.dart';

void main() {
  group('FixtureScoreDto', () {
    test('round-trips through JSON with snake_case wire keys', () {
      const dto = FixtureScoreDto(
        fixtureId: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
        homeGoals: 2,
        awayGoals: 1,
      );
      final json = dto.toJson();
      expect(
        json.keys,
        containsAll(<String>['fixture_id', 'home_goals', 'away_goals']),
      );
      expect(FixtureScoreDto.fromJson(json), dto);
    });

    test('value equality is by field, not identity', () {
      const a = FixtureScoreDto(fixtureId: 'f', homeGoals: 0, awayGoals: 0);
      const b = FixtureScoreDto(fixtureId: 'f', homeGoals: 0, awayGoals: 0);
      const c = FixtureScoreDto(fixtureId: 'f', homeGoals: 1, awayGoals: 0);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });

  group('SubmitPredictionCommandDto', () {
    test('round-trips through JSON, preserving score order', () {
      const dto = SubmitPredictionCommandDto(
        fixtureScores: [
          FixtureScoreDto(fixtureId: 'f1', homeGoals: 1, awayGoals: 0),
          FixtureScoreDto(fixtureId: 'f2', homeGoals: 0, awayGoals: 3),
        ],
      );
      final decoded = SubmitPredictionCommandDto.fromJson(dto.toJson());
      expect(decoded, dto);
      expect(
        decoded.schemaVersion,
        SubmitPredictionCommandDto.currentSchemaVersion,
      );
      expect(decoded.fixtureScores.first.fixtureId, 'f1');
      expect(decoded.fixtureScores.last.fixtureId, 'f2');
    });

    test('defaults schema_version to 1 when absent (back-compat)', () {
      final decoded = SubmitPredictionCommandDto.fromJson(const {
        'fixture_scores': [
          {'fixture_id': 'f', 'home_goals': 2, 'away_goals': 2},
        ],
      });
      expect(decoded.schemaVersion, 1);
      expect(decoded.fixtureScores, hasLength(1));
    });

    test('body carries no participant field (server resolves principal)', () {
      const dto = SubmitPredictionCommandDto(
        fixtureScores: [
          FixtureScoreDto(fixtureId: 'f', homeGoals: 0, awayGoals: 0),
        ],
      );
      final json = dto.toJson();
      expect(json.containsKey('participant_id'), isFalse);
      expect(json.containsKey('round_id'), isFalse);
    });

    test('order-significant equality (reordered scores are not equal)', () {
      const a = SubmitPredictionCommandDto(
        fixtureScores: [
          FixtureScoreDto(fixtureId: 'f1', homeGoals: 1, awayGoals: 0),
          FixtureScoreDto(fixtureId: 'f2', homeGoals: 0, awayGoals: 1),
        ],
      );
      const b = SubmitPredictionCommandDto(
        fixtureScores: [
          FixtureScoreDto(fixtureId: 'f2', homeGoals: 0, awayGoals: 1),
          FixtureScoreDto(fixtureId: 'f1', homeGoals: 1, awayGoals: 0),
        ],
      );
      expect(a, isNot(b));
    });
  });

  group('PredictionDto', () {
    const dto = PredictionDto(
      id: '11111111-1111-1111-1111-111111111111',
      participantId: '22222222-2222-2222-2222-222222222222',
      roundId: '33333333-3333-3333-3333-333333333333',
      submittedAt: '2026-07-10T12:00:00.000Z',
      fixtureScores: [
        FixtureScoreDto(fixtureId: 'f1', homeGoals: 2, awayGoals: 1),
      ],
    );

    test('round-trips through JSON', () {
      final decoded = PredictionDto.fromJson(dto.toJson());
      expect(decoded, dto);
      expect(decoded.schemaVersion, PredictionDto.currentSchemaVersion);
    });

    test('toJson uses snake_case wire keys', () {
      final json = dto.toJson();
      expect(
        json.keys,
        containsAll(<String>[
          'schema_version',
          'id',
          'participant_id',
          'round_id',
          'submitted_at',
          'fixture_scores',
        ]),
      );
    });

    test('carries no points/score/competitive-record value', () {
      final json = dto.toJson();
      expect(json.containsKey('points'), isFalse);
      expect(json.containsKey('score'), isFalse);
      expect(json.containsKey('rank'), isFalse);
    });

    test('defaults schema_version to 1 when absent (back-compat)', () {
      final decoded = PredictionDto.fromJson(const {
        'id': 'i',
        'participant_id': 'p',
        'round_id': 'r',
        'submitted_at': '2026-07-10T00:00:00.000Z',
        'fixture_scores': <Object?>[],
      });
      expect(decoded.schemaVersion, 1);
      expect(decoded.fixtureScores, isEmpty);
    });
  });
}
