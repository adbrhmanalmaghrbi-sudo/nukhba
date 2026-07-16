import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import '../competition/fakes.dart';
import 'fakes.dart';

const _fixture = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
const _admin = 'dddddddd-dddd-dddd-dddd-dddddddddddd';
const _user = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee';

void main() {
  late FakeFixtureResultRepository results;
  late RecordFixtureResult useCase;

  setUp(() {
    results = FakeFixtureResultRepository();
    useCase = RecordFixtureResult(
      resultRepository: results,
      clock: FixedClock(DateTime.utc(2026, 7, 11, 18)),
    );
  });

  test('admin records a valid result and it is stored', () async {
    final r = await useCase.call(
      principal: adminPrincipal(_admin),
      fixtureId: _fixture,
      homeGoals: 2,
      awayGoals: 1,
    );
    expect(r, isA<Ok<FixtureResult>>());
    expect((r as Ok<FixtureResult>).value.homeGoals, 2);
    expect(r.value.outcome, MatchOutcome.homeWin);
    expect(results.count, 1);
  });

  test(
    'a non-admin user is rejected (authorization) and nothing is stored',
    () async {
      final r = await useCase.call(
        principal: userPrincipal(_user),
        fixtureId: _fixture,
        homeGoals: 0,
        awayGoals: 0,
      );
      expect(r, isA<Err<FixtureResult>>());
      expect((r as Err<FixtureResult>).error.kind, ErrorKind.authorization);
      expect(results.count, 0);
    },
  );

  test('a malformed fixture id is a validation error', () async {
    final r = await useCase.call(
      principal: adminPrincipal(_admin),
      fixtureId: 'not-a-uuid',
      homeGoals: 1,
      awayGoals: 0,
    );
    expect(r, isA<Err<FixtureResult>>());
    expect((r as Err<FixtureResult>).error.kind, ErrorKind.validation);
    expect(results.count, 0);
  });

  test('a negative scoreline is rejected by the domain value object', () async {
    final r = await useCase.call(
      principal: adminPrincipal(_admin),
      fixtureId: _fixture,
      homeGoals: -1,
      awayGoals: 0,
    );
    expect(r, isA<Err<FixtureResult>>());
    expect((r as Err<FixtureResult>).error.code, 'scoring.result_negative');
    expect(results.count, 0);
  });

  test('recording twice upserts in place (idempotent correction)', () async {
    await useCase.call(
      principal: adminPrincipal(_admin),
      fixtureId: _fixture,
      homeGoals: 1,
      awayGoals: 1,
    );
    final corrected = await useCase.call(
      principal: adminPrincipal(_admin),
      fixtureId: _fixture,
      homeGoals: 3,
      awayGoals: 0,
    );
    expect(corrected, isA<Ok<FixtureResult>>());
    expect(results.count, 1);
    final stored = await results.findByFixture(const FixtureRef(_fixture));
    expect((stored as Ok<FixtureResult?>).value!.homeGoals, 3);
  });

  test('a transient storage failure propagates unchanged', () async {
    results.failNextWith(const AppError.transient('db.down', 'unavailable'));
    final r = await useCase.call(
      principal: adminPrincipal(_admin),
      fixtureId: _fixture,
      homeGoals: 0,
      awayGoals: 0,
    );
    expect((r as Err<FixtureResult>).error.kind, ErrorKind.transient);
  });
}
