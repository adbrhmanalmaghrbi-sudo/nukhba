import 'package:shared/shared.dart';

/// The frozen ruleset captured on a [Round] at the moment it opens
/// (Database ADR, Section 3: "the snapshot is written once at lock and never
/// mutated"; Domain-invariants section: "the round's `ruleset_snapshot` is
/// write-once").
///
/// Why a snapshot, not a live reference: rules are frozen the instant a round
/// opens so that changing the active ruleset later can *never* alter a
/// historical round's scoring (Next-Task brief; the founding requirement behind
/// this whole value object). The authoritative ruleset lives in the Scoring
/// context (rules-as-data — Application ADR, Section: "Scoring owns ruleset and
/// scoring-definition tables"), which is a later phase. Until it exists,
/// Competition treats the snapshot as an *opaque, structured, immutable*
/// payload it copies verbatim and never interprets — preserving the seam so the
/// Scoring phase can give the payload meaning without Competition changing.
///
/// Immutability is enforced deeply: the constructor takes an unmodifiable deep
/// copy, and [payload] hands back an unmodifiable view, so no caller can mutate
/// a frozen snapshot after the fact.
final class RulesetSnapshot {
  const RulesetSnapshot._(this._payload, this.rulesetVersion);

  /// Creates a frozen snapshot from an arbitrary structured [payload] and its
  /// originating [rulesetVersion].
  ///
  /// Returns a validation [AppError] when the payload is empty (a round must
  /// freeze *some* rules) or the version is not positive. The payload is deep-
  /// copied into unmodifiable collections so the returned snapshot cannot be
  /// mutated through the caller's original reference.
  static Result<RulesetSnapshot> create({
    required Map<String, Object?> payload,
    required int rulesetVersion,
  }) {
    if (payload.isEmpty) {
      return const Result.err(
        AppError.validation(
          'competition.ruleset_snapshot_empty',
          'A round must freeze a non-empty ruleset snapshot',
        ),
      );
    }
    if (rulesetVersion < 1) {
      return const Result.err(
        AppError.validation(
          'competition.ruleset_version_invalid',
          'Ruleset version must be a positive integer',
        ),
      );
    }
    return Result.ok(
      RulesetSnapshot._(
        _deepUnmodifiable(payload) as Map<String, Object?>,
        rulesetVersion,
      ),
    );
  }

  final Map<String, Object?> _payload;

  /// The version of the source ruleset this snapshot was taken from. Recorded so
  /// the Scoring phase can trace a round back to the exact rules that governed
  /// it, and so replay is reproducible (Database ADR, Section: event-sourced
  /// replay reproducibility).
  final int rulesetVersion;

  /// An unmodifiable view of the frozen rule payload. Structurally opaque to
  /// Competition; only the Scoring context interprets its keys.
  Map<String, Object?> get payload => _payload;

  /// Recursively wraps maps and lists in unmodifiable views so the snapshot is
  /// immutable all the way down. Scalars are returned as-is (they are already
  /// immutable in Dart).
  static Object? _deepUnmodifiable(Object? value) {
    if (value is Map) {
      return Map<String, Object?>.unmodifiable({
        for (final entry in value.entries)
          entry.key.toString(): _deepUnmodifiable(entry.value),
      });
    }
    if (value is List) {
      return List<Object?>.unmodifiable(value.map(_deepUnmodifiable));
    }
    return value;
  }

  @override
  bool operator ==(Object other) =>
      other is RulesetSnapshot &&
      other.rulesetVersion == rulesetVersion &&
      _deepEquals(other._payload, _payload);

  @override
  int get hashCode => Object.hash(rulesetVersion, _deepHash(_payload));

  @override
  String toString() =>
      'RulesetSnapshot(v$rulesetVersion, ${_payload.length} keys)';

  static bool _deepEquals(Object? a, Object? b) {
    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      for (final key in a.keys) {
        if (!b.containsKey(key)) return false;
        if (!_deepEquals(a[key], b[key])) return false;
      }
      return true;
    }
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!_deepEquals(a[i], b[i])) return false;
      }
      return true;
    }
    return a == b;
  }

  static int _deepHash(Object? value) {
    if (value is Map) {
      // Order-independent hash over entries so equal maps hash equally.
      var acc = 0;
      for (final entry in value.entries) {
        acc ^= Object.hash(entry.key, _deepHash(entry.value));
      }
      return acc;
    }
    if (value is List) {
      return Object.hashAll(value.map(_deepHash));
    }
    return value.hashCode;
  }
}
