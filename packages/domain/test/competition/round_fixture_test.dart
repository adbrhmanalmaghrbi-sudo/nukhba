import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

const _roundId = '11111111-1111-1111-1111-111111111111';
const _fixtureId = '22222222-2222-2222-2222-222222222222';

void main() {
  group('RoundFixture.create', () {
    test('creates a link with a valid non-negative order', () {
      final result = RoundFixture.create(
        roundId: const RoundId(_roundId),
        fixture: const FixtureRef(_fixtureId),
        displayOrder: 0,
      );
      final link = (result as Ok<RoundFixture>).value;
      expect(link.roundId, const RoundId(_roundId));
      expect(link.fixture, const FixtureRef(_fixtureId));
      expect(link.displayOrder, 0);
    });

    test('rejects a negative display order', () {
      final result = RoundFixture.create(
        roundId: const RoundId(_roundId),
        fixture: const FixtureRef(_fixtureId),
        displayOrder: -1,
      );
      final error = (result as Err<RoundFixture>).error;
      expect(error.kind, ErrorKind.validation);
      expect(error.code, 'competition.round_fixture_order_invalid');
    });
  });

  group('RoundFixture equality', () {
    test('identical links compare equal', () {
      RoundFixture make() =>
          (RoundFixture.create(
                    roundId: const RoundId(_roundId),
                    fixture: const FixtureRef(_fixtureId),
                    displayOrder: 2,
                  )
                  as Ok<RoundFixture>)
              .value;
      expect(make(), make());
      expect(make().hashCode, make().hashCode);
    });

    test('differing fixture breaks equality', () {
      final a =
          (RoundFixture.create(
                    roundId: const RoundId(_roundId),
                    fixture: const FixtureRef(_fixtureId),
                    displayOrder: 0,
                  )
                  as Ok<RoundFixture>)
              .value;
      final b =
          (RoundFixture.create(
                    roundId: const RoundId(_roundId),
                    fixture: const FixtureRef(
                      '33333333-3333-3333-3333-333333333333',
                    ),
                    displayOrder: 0,
                  )
                  as Ok<RoundFixture>)
              .value;
      expect(a, isNot(b));
    });
  });
}
