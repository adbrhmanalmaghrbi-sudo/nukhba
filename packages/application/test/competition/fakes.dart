import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// Deterministic [IdGenerator] for use-case tests: yields a scripted sequence of
/// UUIDs so a test can assert the exact id an aggregate was created with. When
/// the script is exhausted it repeats the last id (tests that don't care about
/// id order just need *some* valid UUID).
final class FakeIdGenerator implements IdGenerator {
  FakeIdGenerator(this._ids) : assert(_ids.length > 0, 'need at least one id');

  final List<String> _ids;
  int _index = 0;

  @override
  String newUuid() {
    final id = _index < _ids.length ? _ids[_index] : _ids.last;
    _index++;
    return id;
  }
}

/// Fixed [Clock] returning a single UTC instant, so participant `joinedAt`
/// timestamps are exactly assertable.
final class FixedClock implements Clock {
  FixedClock(this._now);
  final DateTime _now;

  @override
  DateTime nowUtc() => _now;
}

/// [RulesetProvider] returning a scripted result, so OpenRound tests control the
/// snapshot (and can simulate "no ruleset for format").
final class FakeRulesetProvider implements RulesetProvider {
  FakeRulesetProvider(this._response);
  final Result<RulesetSnapshot> _response;

  FormatType? lastFormat;

  @override
  Future<Result<RulesetSnapshot>> currentSnapshotFor(FormatType format) async {
    lastFormat = format;
    return _response;
  }
}

/// Builds a valid ruleset snapshot for tests.
RulesetSnapshot testSnapshot({int version = 1}) =>
    (RulesetSnapshot.create(
              payload: const {'points': 5},
              rulesetVersion: version,
            )
            as Ok<RulesetSnapshot>)
        .value;

/// A canonical admin principal.
AuthenticatedUser adminPrincipal(String userId) =>
    AuthenticatedUser(userId: UserId(userId), role: PlatformRole.admin);

/// A canonical plain-user principal.
AuthenticatedUser userPrincipal(String userId) =>
    AuthenticatedUser(userId: UserId(userId), role: PlatformRole.user);
