import 'package:domain/domain.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

void main() {
  group('RulesetSnapshot.create', () {
    test(
      'creates a snapshot from a non-empty payload and positive version',
      () {
        final result = RulesetSnapshot.create(
          payload: const {'points': 5},
          rulesetVersion: 3,
        );
        final snapshot = (result as Ok<RulesetSnapshot>).value;
        expect(snapshot.rulesetVersion, 3);
        expect(snapshot.payload['points'], 5);
      },
    );

    test('rejects an empty payload', () {
      final result = RulesetSnapshot.create(
        payload: const {},
        rulesetVersion: 1,
      );
      final error = (result as Err<RulesetSnapshot>).error;
      expect(error.kind, ErrorKind.validation);
      expect(error.code, 'competition.ruleset_snapshot_empty');
    });

    test('rejects a non-positive version', () {
      final result = RulesetSnapshot.create(
        payload: const {'x': 1},
        rulesetVersion: 0,
      );
      final error = (result as Err<RulesetSnapshot>).error;
      expect(error.kind, ErrorKind.validation);
      expect(error.code, 'competition.ruleset_version_invalid');
    });
  });

  group('deep immutability', () {
    test(
      'mutating the source map after create does not affect the snapshot',
      () {
        final source = <String, Object?>{'points': 5};
        final snapshot =
            (RulesetSnapshot.create(payload: source, rulesetVersion: 1)
                    as Ok<RulesetSnapshot>)
                .value;

        source['points'] = 999; // mutate the caller's original reference
        expect(snapshot.payload['points'], 5); // snapshot unchanged
      },
    );

    test('the returned payload view is unmodifiable (top level)', () {
      final snapshot =
          (RulesetSnapshot.create(
                    payload: const {'points': 5},
                    rulesetVersion: 1,
                  )
                  as Ok<RulesetSnapshot>)
              .value;
      expect(() => snapshot.payload['points'] = 1, throwsUnsupportedError);
    });

    test('nested maps and lists are deeply unmodifiable', () {
      final snapshot =
          (RulesetSnapshot.create(
                    payload: const {
                      'nested': {'a': 1},
                      'list': [1, 2, 3],
                    },
                    rulesetVersion: 1,
                  )
                  as Ok<RulesetSnapshot>)
              .value;

      final nested = snapshot.payload['nested']! as Map<String, Object?>;
      expect(() => nested['a'] = 2, throwsUnsupportedError);
      final list = snapshot.payload['list']! as List<Object?>;
      expect(() => list.add(4), throwsUnsupportedError);
    });
  });

  group('value equality (deep)', () {
    test('structurally equal snapshots are equal regardless of key order', () {
      final a =
          (RulesetSnapshot.create(
                    payload: const {'a': 1, 'b': 2},
                    rulesetVersion: 1,
                  )
                  as Ok<RulesetSnapshot>)
              .value;
      final b =
          (RulesetSnapshot.create(
                    payload: const {'b': 2, 'a': 1},
                    rulesetVersion: 1,
                  )
                  as Ok<RulesetSnapshot>)
              .value;
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('a differing version breaks equality', () {
      final a =
          (RulesetSnapshot.create(payload: const {'a': 1}, rulesetVersion: 1)
                  as Ok<RulesetSnapshot>)
              .value;
      final b =
          (RulesetSnapshot.create(payload: const {'a': 1}, rulesetVersion: 2)
                  as Ok<RulesetSnapshot>)
              .value;
      expect(a, isNot(b));
    });

    test('a differing nested value breaks equality', () {
      final a =
          (RulesetSnapshot.create(
                    payload: const {
                      'nested': {'a': 1},
                    },
                    rulesetVersion: 1,
                  )
                  as Ok<RulesetSnapshot>)
              .value;
      final b =
          (RulesetSnapshot.create(
                    payload: const {
                      'nested': {'a': 2},
                    },
                    rulesetVersion: 1,
                  )
                  as Ok<RulesetSnapshot>)
              .value;
      expect(a, isNot(b));
    });
  });
}
