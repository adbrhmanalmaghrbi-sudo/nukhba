import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

const _id = '11111111-2222-3333-4444-555555555555';

Competition _created({
  String name = 'Premier Predictions',
  FormatType format = FormatType.footballScoreline,
  CompetitionVisibility visibility = CompetitionVisibility.public,
}) {
  final result = Competition.create(
    id: const CompetitionId(_id),
    name: name,
    format: format,
    visibility: visibility,
  );
  return (result as Ok<Competition>).value;
}

void main() {
  group('Competition.create', () {
    test('creates a valid competition with a trimmed name', () {
      final result = Competition.create(
        id: const CompetitionId(_id),
        name: '  Premier Predictions  ',
        format: FormatType.footballScoreline,
        visibility: CompetitionVisibility.public,
      );

      final competition = (result as Ok<Competition>).value;
      expect(competition.id, const CompetitionId(_id));
      expect(competition.name, 'Premier Predictions'); // trimmed
      expect(competition.format, FormatType.footballScoreline);
      expect(competition.visibility, CompetitionVisibility.public);
    });

    test('rejects an empty name as a validation error', () {
      final result = Competition.create(
        id: const CompetitionId(_id),
        name: '   ',
        format: FormatType.footballScoreline,
        visibility: CompetitionVisibility.public,
      );

      final error = (result as Err<Competition>).error;
      expect(error.kind, ErrorKind.validation);
      expect(error.code, 'competition.name_empty');
    });

    test('rejects a name longer than 120 chars', () {
      final result = Competition.create(
        id: const CompetitionId(_id),
        name: 'x' * 121,
        format: FormatType.footballScoreline,
        visibility: CompetitionVisibility.public,
      );

      final error = (result as Err<Competition>).error;
      expect(error.kind, ErrorKind.validation);
      expect(error.code, 'competition.name_too_long');
    });

    test('accepts a name of exactly 120 chars after trimming', () {
      final result = Competition.create(
        id: const CompetitionId(_id),
        name: '  ${'x' * 120}  ',
        format: FormatType.footballScoreline,
        visibility: CompetitionVisibility.public,
      );

      expect(result.isOk, isTrue);
      expect((result as Ok<Competition>).value.name.length, 120);
    });
  });

  group('Competition.copyWith', () {
    test('replaces visibility while preserving id/name/format', () {
      final competition = _created();
      final copy = competition.copyWith(
        visibility: CompetitionVisibility.private,
      );

      expect(copy.visibility, CompetitionVisibility.private);
      expect(copy.id, competition.id);
      expect(copy.name, competition.name);
      expect(copy.format, competition.format);
    });

    test('returns an equal value when nothing is changed', () {
      final competition = _created();
      expect(competition.copyWith(), competition);
    });
  });

  group('Competition equality', () {
    test('two competitions with identical fields are equal', () {
      expect(_created(), _created());
      expect(_created().hashCode, _created().hashCode);
    });

    test('differing name breaks equality', () {
      expect(_created(name: 'A'), isNot(_created(name: 'B')));
    });
  });

  group('Competition.fromStored', () {
    test('rehydrates without re-validating', () {
      const competition = Competition.fromStored(
        id: CompetitionId(_id),
        // fromStored trusts input: no trimming/length check applied.
        name: '  already trusted  ',
        format: FormatType.footballScoreline,
        visibility: CompetitionVisibility.private,
      );
      expect(competition.name, '  already trusted  ');
      expect(competition.visibility, CompetitionVisibility.private);
    });
  });
}
