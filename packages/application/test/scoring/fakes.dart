import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// A complete in-memory [FixtureResultRepository] for use-case tests.
///
/// Reproduces the observable contract the Postgres adapter must honour — upsert
/// idempotency per fixture, find-by-fixture, and the by-fixtures batch read that
/// simply omits fixtures with no recorded result (so the scoring use-case
/// detects a gap by count). It never throws.
final class FakeFixtureResultRepository implements FixtureResultRepository {
  /// keyed by fixture id.
  final Map<String, FixtureResult> _byFixture = {};

  AppError? _scriptedFailure;

  /// Scripts the *next* call to fail with [error], then clears the script.
  void failNextWith(AppError error) => _scriptedFailure = error;

  AppError? _takeFailure() {
    final f = _scriptedFailure;
    _scriptedFailure = null;
    return f;
  }

  /// Seeds a result directly (tests arrange state without the admin command).
  void seed(FixtureResult result) => _byFixture[result.fixture.value] = result;

  int get count => _byFixture.length;

  @override
  Future<Result<void>> upsert(FixtureResult result, DateTime recordedAt) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    _byFixture[result.fixture.value] = result;
    return const Result.ok(null);
  }

  @override
  Future<Result<FixtureResult?>> findByFixture(FixtureRef fixture) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    return Result.ok(_byFixture[fixture.value]);
  }

  @override
  Future<Result<List<FixtureResult>>> findByFixtures(
    List<FixtureRef> fixtures,
  ) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    return Result.ok(<FixtureResult>[
      for (final ref in fixtures)
        if (_byFixture[ref.value] case final r?) r,
    ]);
  }
}

/// A complete in-memory [ScoreRepository] for use-case tests.
///
/// Reproduces the observable contract: idempotent upsert per
/// `(round, participant)` (re-scoring replaces in place, never duplicates), and
/// a stable by-round read ordered by participant id. It never throws.
final class FakeScoreRepository implements ScoreRepository {
  /// keyed by `${roundId}|${participantId}`.
  final Map<String, RoundScore> _byKey = {};

  AppError? _scriptedFailure;

  /// Scripts the *next* call to fail with [error], then clears the script.
  void failNextWith(AppError error) => _scriptedFailure = error;

  AppError? _takeFailure() {
    final f = _scriptedFailure;
    _scriptedFailure = null;
    return f;
  }

  static String _key(RoundId roundId, ParticipantId participantId) =>
      '${roundId.value}|${participantId.value}';

  /// How many round-score rows are stored (proves idempotent re-scoring keeps
  /// one row per participant).
  int get count => _byKey.length;

  @override
  Future<Result<void>> saveRoundScores(List<RoundScore> scores) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    // Atomic all-or-nothing: build the batch, then commit it in one shot.
    final staged = <String, RoundScore>{};
    for (final s in scores) {
      staged[_key(s.roundId, s.participantId)] = s;
    }
    _byKey.addAll(staged);
    return const Result.ok(null);
  }

  @override
  Future<Result<List<RoundScore>>> listByRound(RoundId roundId) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    final out = <RoundScore>[
      for (final s in _byKey.values)
        if (s.roundId == roundId) s,
    ]..sort((a, b) => a.participantId.value.compareTo(b.participantId.value));
    return Result.ok(out);
  }
}

// ---------------------------------------------------------------------------
// Builders shared across the scoring use-case tests.
// ---------------------------------------------------------------------------

/// The exact football-scoreline payload `ConfiguredRulesetProvider` freezes,
/// wrapped in a validated snapshot at [version].
RulesetSnapshot scoringSnapshot({
  int version = 1,
  int exact = 3,
  int outcome = 1,
  int incorrect = 0,
}) =>
    (RulesetSnapshot.create(
              payload: {
                'format': 'football_scoreline',
                'points': {
                  'exact_scoreline': exact,
                  'correct_outcome': outcome,
                  'incorrect': incorrect,
                },
              },
              rulesetVersion: version,
            )
            as Ok<RulesetSnapshot>)
        .value;

/// Builds a stored round at [status] carrying a scoring [ruleset] snapshot.
Round scoringRound({
  required String id,
  required String seasonId,
  required RoundStatus status,
  int sequence = 1,
  RulesetSnapshot? ruleset,
}) => Round.fromStored(
  id: RoundId(id),
  seasonId: SeasonId(seasonId),
  sequence: sequence,
  predictionDeadline: DateTime.utc(2026),
  status: status,
  ruleset: ruleset ?? scoringSnapshot(),
);

/// Builds a stored active participant.
Participant scoringParticipant({
  required String id,
  required String seasonId,
  required String userId,
}) => Participant.fromStored(
  id: ParticipantId(id),
  seasonId: SeasonId(seasonId),
  userId: UserId(userId),
  status: ParticipantStatus.active,
  joinedAt: DateTime.utc(2026),
);

/// Builds a round↔fixture link.
RoundFixture scoringLink({
  required String roundId,
  required String fixtureId,
  int order = 0,
}) => RoundFixture.fromStored(
  roundId: RoundId(roundId),
  fixture: FixtureRef(fixtureId),
  displayOrder: order,
);

/// Builds an actual fixture result.
FixtureResult scoringResult({
  required String fixtureId,
  required int home,
  required int away,
}) => FixtureResult.fromStored(
  fixture: FixtureRef(fixtureId),
  homeGoals: home,
  awayGoals: away,
);

/// Builds a stored prediction with the given per-fixture scores.
Prediction scoringPrediction({
  required String id,
  required String roundId,
  required String participantId,
  required List<(String fixtureId, int home, int away)> scores,
}) => Prediction.fromStored(
  id: PredictionId(id),
  roundId: RoundId(roundId),
  participantId: ParticipantId(participantId),
  scores: [
    for (final (fixtureId, home, away) in scores)
      (FixtureScorePrediction.create(
                fixture: FixtureRef(fixtureId),
                homeGoals: home,
                awayGoals: away,
              )
              as Ok<FixtureScorePrediction>)
          .value,
  ],
);
