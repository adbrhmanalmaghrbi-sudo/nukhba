import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// A complete in-memory [PredictionRepository] for use-case tests.
///
/// It faithfully reproduces the *observable* contract the Postgres adapter must
/// honour — the `(participant_id, round_id)` uniqueness (Axiom 6 backstop),
/// find/update/list semantics, and the round-fixture composition read — so a
/// use-case test that passes here exercises the same invariants the real
/// adapter enforces via constraints. It never throws.
///
/// Any single call can be forced to return a scripted failure via
/// [failNextWith], letting a test assert the use-case propagates faults
/// unchanged (or that a scripted unique-violation triggers idempotent
/// convergence).
final class FakePredictionRepository implements PredictionRepository {
  /// keyed by `${roundId}|${participantId}`.
  final Map<String, _Stored> _byKey = {};

  /// keyed by roundId → ordered links.
  final Map<String, List<RoundFixture>> _roundFixtures = {};

  AppError? _scriptedFailure;

  /// When set, the *next* [save] call reports the unique-violation
  /// (`prediction.already_submitted`) as if a concurrent writer won the race,
  /// while atomically storing [_raceWinner] so a subsequent re-read finds it —
  /// faithfully reproducing the Postgres `23505` race the use-case must
  /// converge on. Cleared after firing once.
  Prediction? _raceWinner;
  DateTime? _raceWinnerAt;

  /// Arms a one-shot save race: the next [save] fails with the unique violation
  /// and [winner] becomes the stored, findable prediction.
  void armSaveRace(Prediction winner, DateTime submittedAt) {
    _raceWinner = winner;
    _raceWinnerAt = submittedAt;
  }

  /// Scripts the *next* call to fail with [error], then clears the script.
  void failNextWith(AppError error) => _scriptedFailure = error;

  AppError? _takeFailure() {
    final f = _scriptedFailure;
    _scriptedFailure = null;
    return f;
  }

  static String _key(RoundId roundId, ParticipantId participantId) =>
      '${roundId.value}|${participantId.value}';

  // Seeding helpers.
  void seedRoundFixtures(RoundId roundId, List<RoundFixture> links) =>
      _roundFixtures[roundId.value] = List<RoundFixture>.unmodifiable(links);

  void seedPrediction(Prediction prediction, DateTime submittedAt) =>
      _byKey[_key(prediction.roundId, prediction.participantId)] = _Stored(
        prediction,
        submittedAt,
      );

  int get count => _byKey.length;

  DateTime? submittedAtOf(RoundId roundId, ParticipantId participantId) =>
      _byKey[_key(roundId, participantId)]?.submittedAt;

  @override
  Future<Result<PredictionView?>> findByRoundAndParticipant(
    RoundId roundId,
    ParticipantId participantId,
  ) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    final stored = _byKey[_key(roundId, participantId)];
    return Result.ok(
      stored == null
          ? null
          : PredictionView(
              prediction: stored.prediction,
              submittedAt: stored.submittedAt,
            ),
    );
  }

  @override
  Future<Result<void>> save(Prediction prediction, DateTime submittedAt) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    // A one-shot armed race: a concurrent writer's row lands now, and this
    // insert loses with the unique violation.
    if (_raceWinner != null) {
      final winner = _raceWinner!;
      _byKey[_key(winner.roundId, winner.participantId)] = _Stored(
        winner,
        _raceWinnerAt!,
      );
      _raceWinner = null;
      _raceWinnerAt = null;
      return const Result.err(
        AppError.invariant('prediction.already_submitted', 'already submitted'),
      );
    }
    final key = _key(prediction.roundId, prediction.participantId);
    if (_byKey.containsKey(key)) {
      // The physical (participant_id, round_id) unique violation.
      return const Result.err(
        AppError.invariant('prediction.already_submitted', 'already submitted'),
      );
    }
    _byKey[key] = _Stored(prediction, submittedAt);
    return const Result.ok(null);
  }

  @override
  Future<Result<void>> update(
    Prediction prediction,
    DateTime submittedAt,
  ) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    final key = _key(prediction.roundId, prediction.participantId);
    if (!_byKey.containsKey(key)) {
      return const Result.err(
        AppError.invariant('prediction.not_found', 'not found'),
      );
    }
    _byKey[key] = _Stored(prediction, submittedAt);
    return const Result.ok(null);
  }

  @override
  Future<Result<List<PredictionView>>> listByRound(RoundId roundId) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    final out =
        <_Stored>[
          for (final s in _byKey.values)
            if (s.prediction.roundId == roundId) s,
        ]..sort((a, b) {
          final byTime = a.submittedAt.compareTo(b.submittedAt);
          return byTime != 0
              ? byTime
              : a.prediction.id.value.compareTo(b.prediction.id.value);
        });
    return Result.ok([
      for (final s in out)
        PredictionView(prediction: s.prediction, submittedAt: s.submittedAt),
    ]);
  }

  @override
  Future<Result<List<RoundFixture>>> listRoundFixtures(RoundId roundId) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    return Result.ok(_roundFixtures[roundId.value] ?? const <RoundFixture>[]);
  }
}

final class _Stored {
  const _Stored(this.prediction, this.submittedAt);
  final Prediction prediction;
  final DateTime submittedAt;
}
