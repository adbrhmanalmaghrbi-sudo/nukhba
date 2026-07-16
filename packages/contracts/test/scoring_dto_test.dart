import 'package:contracts/contracts.dart';
import 'package:test/test.dart';

void main() {
  group('FixtureScoreResultDto', () {
    test('round-trips through JSON with snake_case wire keys', () {
      const dto = FixtureScoreResultDto(
        fixtureId: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
        grade: 'exact_scoreline',
        points: 3,
      );
      final json = dto.toJson();
      expect(json.keys, containsAll(<String>['fixture_id', 'grade', 'points']));
      expect(FixtureScoreResultDto.fromJson(json), dto);
    });

    test('value equality is by field, not identity', () {
      const a = FixtureScoreResultDto(
        fixtureId: 'f',
        grade: 'incorrect',
        points: 0,
      );
      const b = FixtureScoreResultDto(
        fixtureId: 'f',
        grade: 'incorrect',
        points: 0,
      );
      const c = FixtureScoreResultDto(
        fixtureId: 'f',
        grade: 'correct_outcome',
        points: 1,
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });

  group('RoundScoreDto', () {
    const dto = RoundScoreDto(
      roundId: '33333333-3333-3333-3333-333333333333',
      participantId: '22222222-2222-2222-2222-222222222222',
      rulesetVersion: 1,
      totalPoints: 4,
      fixtureResults: [
        FixtureScoreResultDto(
          fixtureId: 'f1',
          grade: 'exact_scoreline',
          points: 3,
        ),
        FixtureScoreResultDto(
          fixtureId: 'f2',
          grade: 'correct_outcome',
          points: 1,
        ),
      ],
    );

    test('round-trips through JSON, preserving fixture order', () {
      final decoded = RoundScoreDto.fromJson(dto.toJson());
      expect(decoded, dto);
      expect(decoded.schemaVersion, RoundScoreDto.currentSchemaVersion);
      expect(decoded.fixtureResults.first.fixtureId, 'f1');
      expect(decoded.fixtureResults.last.fixtureId, 'f2');
    });

    test('toJson uses snake_case wire keys', () {
      final json = dto.toJson();
      expect(
        json.keys,
        containsAll(<String>[
          'schema_version',
          'round_id',
          'participant_id',
          'ruleset_version',
          'total_points',
          'fixture_results',
        ]),
      );
    });

    test('carries no client-writable rank/prediction field', () {
      final json = dto.toJson();
      expect(json.containsKey('rank'), isFalse);
      expect(json.containsKey('prediction_id'), isFalse);
    });

    test('defaults schema_version to 1 when absent (back-compat)', () {
      final decoded = RoundScoreDto.fromJson(const {
        'round_id': 'r',
        'participant_id': 'p',
        'ruleset_version': 2,
        'total_points': 0,
        'fixture_results': <Object?>[],
      });
      expect(decoded.schemaVersion, 1);
      expect(decoded.fixtureResults, isEmpty);
    });

    test('order-significant equality (reordered results are not equal)', () {
      const a = RoundScoreDto(
        roundId: 'r',
        participantId: 'p',
        rulesetVersion: 1,
        totalPoints: 4,
        fixtureResults: [
          FixtureScoreResultDto(
            fixtureId: 'f1',
            grade: 'exact_scoreline',
            points: 3,
          ),
          FixtureScoreResultDto(
            fixtureId: 'f2',
            grade: 'correct_outcome',
            points: 1,
          ),
        ],
      );
      const b = RoundScoreDto(
        roundId: 'r',
        participantId: 'p',
        rulesetVersion: 1,
        totalPoints: 4,
        fixtureResults: [
          FixtureScoreResultDto(
            fixtureId: 'f2',
            grade: 'correct_outcome',
            points: 1,
          ),
          FixtureScoreResultDto(
            fixtureId: 'f1',
            grade: 'exact_scoreline',
            points: 3,
          ),
        ],
      );
      expect(a, isNot(b));
    });
  });

  group('RoundScoresDto', () {
    const dto = RoundScoresDto(
      roundId: '33333333-3333-3333-3333-333333333333',
      scores: [
        RoundScoreDto(
          roundId: '33333333-3333-3333-3333-333333333333',
          participantId: '22222222-2222-2222-2222-222222222222',
          rulesetVersion: 1,
          totalPoints: 3,
          fixtureResults: [
            FixtureScoreResultDto(
              fixtureId: 'f1',
              grade: 'exact_scoreline',
              points: 3,
            ),
          ],
        ),
      ],
    );

    test('round-trips through JSON', () {
      final decoded = RoundScoresDto.fromJson(dto.toJson());
      expect(decoded, dto);
      expect(decoded.schemaVersion, RoundScoresDto.currentSchemaVersion);
    });

    test('toJson uses snake_case wire keys', () {
      final json = dto.toJson();
      expect(
        json.keys,
        containsAll(<String>['schema_version', 'round_id', 'scores']),
      );
    });

    test('defaults schema_version to 1 when absent (back-compat)', () {
      final decoded = RoundScoresDto.fromJson(const {
        'round_id': 'r',
        'scores': <Object?>[],
      });
      expect(decoded.schemaVersion, 1);
      expect(decoded.scores, isEmpty);
    });
  });
}
