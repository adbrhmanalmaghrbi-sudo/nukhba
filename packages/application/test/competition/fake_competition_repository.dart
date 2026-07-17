import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// A complete in-memory [CompetitionRepository] for use-case tests.
///
/// It faithfully reproduces the *observable* contract the Postgres adapter must
/// honour — id/season/round lookups, the `(seasonId, userId)` participant
/// uniqueness, the `(seasonId, sequence)` round uniqueness, the `(roundId,
/// fixture)` link uniqueness, and the guarded round-status transition — so a
/// use-case test that passes here is exercising the same invariants the real
/// adapter enforces via constraints. It never throws.
///
/// Every method can also be forced to return a scripted transient failure via
/// [failNextWith], letting a test assert the use-case propagates infrastructure
/// faults unchanged.
base class FakeCompetitionRepository implements CompetitionRepository {
  final Map<String, Competition> _competitions = {};
  final Map<String, CompetitionSeason> _seasons = {};
  final Map<String, Round> _rounds = {};
  final Map<String, Participant> _participants = {};
  final Set<String> _roundFixtureKeys = {};

  /// The full round↔fixture link objects, retained alongside the uniqueness
  /// key-set so the browse read [listRoundFixtures] can reproduce the adapter's
  /// `display_order` ordering (the key set alone cannot). Kept in insertion
  /// order; the read sorts a filtered copy.
  final List<RoundFixture> _roundFixtures = [];

  AppError? _scriptedFailure;

  /// Scripts the *next* mutating/reading call to fail with [error], then clears
  /// the script. Used to prove transient-failure propagation.
  void failNextWith(AppError error) => _scriptedFailure = error;

  AppError? _takeFailure() {
    final f = _scriptedFailure;
    _scriptedFailure = null;
    return f;
  }

  // Seeding helpers (tests arrange state without going through commands).
  void seedCompetition(Competition c) => _competitions[c.id.value] = c;
  void seedSeason(CompetitionSeason s) => _seasons[s.id.value] = s;
  void seedRound(Round r) => _rounds[r.id.value] = r;
  void seedParticipant(Participant p) =>
      _participants['${p.seasonId.value}|${p.userId.value}'] = p;

  int get roundFixtureCount => _roundFixtureKeys.length;
  Round? round(String id) => _rounds[id];

  @override
  Future<Result<void>> saveCompetition(Competition competition) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    if (_competitions.containsKey(competition.id.value)) {
      return const Result.err(
        AppError.invariant('competition.duplicate_id', 'duplicate'),
      );
    }
    _competitions[competition.id.value] = competition;
    return const Result.ok(null);
  }

  @override
  Future<Result<Competition>> findCompetition(CompetitionId id) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    final c = _competitions[id.value];
    return c == null
        ? const Result.err(
            AppError.invariant('competition.not_found', 'not found'),
          )
        : Result.ok(c);
  }

  @override
  Future<Result<void>> saveSeason(CompetitionSeason season) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    if (!_competitions.containsKey(season.competitionId.value)) {
      return const Result.err(
        AppError.invariant('competition.not_found', 'competition not found'),
      );
    }
    if (_seasons.containsKey(season.id.value)) {
      return const Result.err(
        AppError.invariant('competition.duplicate_id', 'duplicate'),
      );
    }
    _seasons[season.id.value] = season;
    return const Result.ok(null);
  }

  @override
  Future<Result<CompetitionSeason>> findSeason(SeasonId id) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    final s = _seasons[id.value];
    return s == null
        ? const Result.err(
            AppError.invariant('competition.season_not_found', 'not found'),
          )
        : Result.ok(s);
  }

  @override
  Future<Result<void>> saveRound(Round round) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    if (!_seasons.containsKey(round.seasonId.value)) {
      return const Result.err(
        AppError.invariant('competition.season_not_found', 'season not found'),
      );
    }
    // (seasonId, sequence) uniqueness.
    final clash = _rounds.values.any(
      (r) => r.seasonId == round.seasonId && r.sequence == round.sequence,
    );
    if (clash) {
      return const Result.err(
        AppError.invariant(
          'competition.round_sequence_conflict',
          'duplicate sequence',
        ),
      );
    }
    _rounds[round.id.value] = round;
    return const Result.ok(null);
  }

  @override
  Future<Result<Round>> findRound(RoundId id) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    final r = _rounds[id.value];
    return r == null
        ? const Result.err(
            AppError.invariant('competition.round_not_found', 'not found'),
          )
        : Result.ok(r);
  }

  @override
  Future<Result<void>> updateRoundStatus(
    Round round,
    RoundStatus expectedPriorStatus,
  ) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    final stored = _rounds[round.id.value];
    // Guarded update: the stored status must still match the expected prior.
    if (stored == null || stored.status != expectedPriorStatus) {
      return const Result.err(
        AppError.invariant(
          'competition.round_transition_conflict',
          'concurrent transition',
        ),
      );
    }
    _rounds[round.id.value] = round;
    return const Result.ok(null);
  }

  @override
  Future<Result<void>> saveRoundFixture(RoundFixture link) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    final key = '${link.roundId.value}|${link.fixture.value}';
    if (_roundFixtureKeys.contains(key)) {
      return const Result.err(
        AppError.invariant(
          'competition.fixture_already_linked',
          'already linked',
        ),
      );
    }
    _roundFixtureKeys.add(key);
    _roundFixtures.add(link);
    return const Result.ok(null);
  }

  @override
  Future<Result<void>> saveParticipant(Participant participant) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    final key = '${participant.seasonId.value}|${participant.userId.value}';
    if (_participants.containsKey(key)) {
      return const Result.err(
        AppError.invariant('competition.already_joined', 'already joined'),
      );
    }
    _participants[key] = participant;
    return const Result.ok(null);
  }

  @override
  Future<Result<Participant?>> findParticipant(
    SeasonId seasonId,
    UserId userId,
  ) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    return Result.ok(_participants['${seasonId.value}|${userId.value}']);
  }

  // ---------------------------------------------------------------------------
  // Read-only browse surface (BLOCKER FA-1 / DEFECT FA-2). Real in-memory
  // reads over the same backing stores the write methods above use — NOT
  // stubs/throws — so use-case tests exercise the same observable contract the
  // Postgres adapter honours (public-only catalogue name-ordered; a season's
  // rounds sequence-ordered; a round's fixtures display_order-ordered). Each
  // still respects the scripted [failNextWith] transient-failure hook, and an
  // empty result is a legitimate `Ok(<empty list>)`.
  // ---------------------------------------------------------------------------

  @override
  Future<Result<List<Competition>>> listCompetitions() async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    // Public catalogue only, ordered by name then id (matches the adapter's
    // `WHERE visibility = 'public' ORDER BY name ASC, id ASC`).
    final catalogue =
        [
          for (final c in _competitions.values)
            if (c.visibility == CompetitionVisibility.public) c,
        ]..sort((a, b) {
          final byName = a.name.compareTo(b.name);
          return byName != 0 ? byName : a.id.value.compareTo(b.id.value);
        });
    return Result.ok(catalogue);
  }

  @override
  Future<Result<List<CompetitionSeason>>> listCompetitionSeasons(
    CompetitionId competitionId,
  ) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    // A competition's seasons ordered by label then id (matches the adapter's
    // `WHERE competition_id = @competition_id ORDER BY label ASC, id ASC`).
    // Absent/empty competition → []; a browse read reveals no existence oracle.
    final competitionSeasons =
        [
          for (final s in _seasons.values)
            if (s.competitionId.value == competitionId.value) s,
        ]..sort((a, b) {
          final byLabel = a.label.compareTo(b.label);
          return byLabel != 0 ? byLabel : a.id.value.compareTo(b.id.value);
        });
    return Result.ok(competitionSeasons);
  }

  @override
  Future<Result<List<Round>>> listSeasonRounds(SeasonId seasonId) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    // A season's rounds ordered by 1-based sequence (matches the adapter's
    // `WHERE season_id = @season_id ORDER BY sequence ASC`). Absent/empty
    // season → []; a browse read reveals no existence oracle.
    final seasonRounds = [
      for (final r in _rounds.values)
        if (r.seasonId.value == seasonId.value) r,
    ]..sort((a, b) => a.sequence.compareTo(b.sequence));
    return Result.ok(seasonRounds);
  }

  @override
  Future<Result<List<RoundFixture>>> listRoundFixtures(RoundId roundId) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    // The round's fixtures in matchday (display_order) order, tie-broken by
    // fixture id (matches the adapter's `WHERE round_id = @round_id
    // ORDER BY display_order ASC, fixture_id ASC`). Absent/empty round → [].
    final roundLinks =
        [
          for (final link in _roundFixtures)
            if (link.roundId.value == roundId.value) link,
        ]..sort((a, b) {
          final byOrder = a.displayOrder.compareTo(b.displayOrder);
          return byOrder != 0
              ? byOrder
              : a.fixture.value.compareTo(b.fixture.value);
        });
    return Result.ok(roundLinks);
  }
}
