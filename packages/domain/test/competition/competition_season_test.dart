import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

const _seasonId = '11111111-1111-1111-1111-111111111111';
const _competitionId = '22222222-2222-2222-2222-222222222222';

void main() {
  group('CompetitionSeason.create', () {
    test('creates a valid season with a trimmed label', () {
      final result = CompetitionSeason.create(
        id: const SeasonId(_seasonId),
        competitionId: const CompetitionId(_competitionId),
        label: '  2026/27  ',
      );

      final season = (result as Ok<CompetitionSeason>).value;
      expect(season.id, const SeasonId(_seasonId));
      expect(season.competitionId, const CompetitionId(_competitionId));
      expect(season.label, '2026/27'); // trimmed
    });

    test('rejects an empty label', () {
      final result = CompetitionSeason.create(
        id: const SeasonId(_seasonId),
        competitionId: const CompetitionId(_competitionId),
        label: '   ',
      );

      final error = (result as Err<CompetitionSeason>).error;
      expect(error.kind, ErrorKind.validation);
      expect(error.code, 'competition.season_label_empty');
    });

    test('rejects a label longer than 60 chars', () {
      final result = CompetitionSeason.create(
        id: const SeasonId(_seasonId),
        competitionId: const CompetitionId(_competitionId),
        label: 'x' * 61,
      );

      final error = (result as Err<CompetitionSeason>).error;
      expect(error.kind, ErrorKind.validation);
      expect(error.code, 'competition.season_label_too_long');
    });

    test('accepts a label of exactly 60 chars', () {
      final result = CompetitionSeason.create(
        id: const SeasonId(_seasonId),
        competitionId: const CompetitionId(_competitionId),
        label: 'x' * 60,
      );
      expect(result.isOk, isTrue);
    });
  });

  group('CompetitionSeason equality', () {
    test('identical fields compare equal', () {
      CompetitionSeason make() =>
          (CompetitionSeason.create(
                    id: const SeasonId(_seasonId),
                    competitionId: const CompetitionId(_competitionId),
                    label: '2026/27',
                  )
                  as Ok<CompetitionSeason>)
              .value;
      expect(make(), make());
      expect(make().hashCode, make().hashCode);
    });

    test('differing competition breaks equality', () {
      final a =
          (CompetitionSeason.create(
                    id: const SeasonId(_seasonId),
                    competitionId: const CompetitionId(_competitionId),
                    label: 'x',
                  )
                  as Ok<CompetitionSeason>)
              .value;
      final b =
          (CompetitionSeason.create(
                    id: const SeasonId(_seasonId),
                    competitionId: const CompetitionId(
                      '33333333-3333-3333-3333-333333333333',
                    ),
                    label: 'x',
                  )
                  as Ok<CompetitionSeason>)
              .value;
      expect(a, isNot(b));
    });
  });
}
