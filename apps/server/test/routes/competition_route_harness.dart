import 'dart:convert';

import 'package:application/application.dart';
export 'package:dart_frog/dart_frog.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:domain/domain.dart';
import 'package:mocktail/mocktail.dart';
import 'package:server/composition/composition_root.dart';
import 'package:shared/shared.dart';

/// Shared harness for the Competition command-route tests.
///
/// The routes are tested the way `me_test.dart` tests `/me`: through the *real*
/// wiring (`context.read<Future<CompositionRoot>>()` → `root.<useCase>()`),
/// with the use-cases assembled over an in-memory [InMemoryCompetitionRepository]
/// rather than a stubbed use-case. This exercises the edge → use-case →
/// domain → port path end-to-end, hermetically, so the assertions cover the
/// route's status mapping, DTO shaping, and body/field validation for real.

/// Canonical UUIDs the tests reuse.
const kCompetitionId = '11111111-1111-1111-1111-111111111111';
const kSeasonId = '22222222-2222-2222-2222-222222222222';
const kRoundId = '33333333-3333-3333-3333-333333333333';
// A second, distinct round id — for tests that credit a participant across
// two separate rounds (a single round_score entry is unique per
// (participant, round); crediting the "same" round twice is a re-post and
// is correctly deduped, not a second entry).
const kRoundId2 = '34343434-3434-3434-3434-343434343434';
const kFixtureId = '66666666-6666-6666-6666-666666666666';
const kAdminId = '77777777-7777-7777-7777-777777777777';
const kUserId = '88888888-8888-8888-8888-888888888888';

/// Canonical UUIDs the Groups route tests reuse.
const kGroupId = '99999999-9999-9999-9999-999999999999';
const kOwnerMembershipId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
const kMemberMembershipId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
const kOwnerUserId = 'cccccccc-cccc-cccc-cccc-cccccccccccc';
const kMemberUserId = 'dddddddd-dddd-dddd-dddd-dddddddddddd';
const kNonMemberUserId = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee';
const kParticipantId = 'ffffffff-ffff-ffff-ffff-ffffffffffff';
const kParticipantId2 = 'fefefefe-fefe-fefe-fefe-fefefefefefe';

/// Canonical UUIDs the Social route tests reuse.
const kReactionId = 'a1a1a1a1-a1a1-a1a1-a1a1-a1a1a1a1a1a1';
const kReactionId2 = 'a2a2a2a2-a2a2-a2a2-a2a2-a2a2a2a2a2a2';

/// Canonical UUIDs the Notifications route tests reuse.
const kNotificationId = 'b1b1b1b1-b1b1-b1b1-b1b1-b1b1b1b1b1b1';
const kNotificationId2 = 'b2b2b2b2-b2b2-b2b2-b2b2-b2b2b2b2b2b2';
const kNotificationId3 = 'b3b3b3b3-b3b3-b3b3-b3b3-b3b3b3b3b3b3';

/// Canonical UUIDs the Admin route tests reuse.
const kTargetUserId = 'c1c1c1c1-c1c1-c1c1-c1c1-c1c1c1c1c1c1';
const kAuditEntryId = 'c2c2c2c2-c2c2-c2c2-c2c2-c2c2c2c2c2c2';
const kAuditEntryId2 = 'c3c3c3c3-c3c3-c3c3-c3c3-c3c3c3c3c3c3';

/// A well-formed invite code (10 chars over the [InviteCode] alphabet).
const kInviteCode = 'ABCDEFGHJK';

/// A second well-formed invite code (for regeneration/rotation tests).
const kRotatedInviteCode = 'MNPQRSTUVW';

/// A minimal in-memory [CompetitionRepository] for route tests. It stores
/// aggregates in maps and enforces just enough of the storage contract (the
/// unique/found/absent outcomes the use-cases branch on) to make the real
/// use-cases behave. It is NOT a substitute for the Postgres adapter's own
/// tests — those live in the infrastructure package.
final class InMemoryCompetitionRepository implements CompetitionRepository {
  final Map<String, Competition> competitions = {};
  final Map<String, CompetitionSeason> seasons = {};
  final Map<String, Round> rounds = {};
  final List<RoundFixture> links = [];
  final List<Participant> participants = [];

  @override
  Future<Result<void>> saveCompetition(Competition competition) async {
    competitions[competition.id.value] = competition;
    return const Result.ok(null);
  }

  @override
  Future<Result<Competition>> findCompetition(CompetitionId id) async {
    final found = competitions[id.value];
    return found == null
        ? const Result.err(
            AppError.invariant(
              'competition.not_found',
              'Competition not found',
            ),
          )
        : Result.ok(found);
  }

  @override
  Future<Result<void>> saveSeason(CompetitionSeason season) async {
    seasons[season.id.value] = season;
    return const Result.ok(null);
  }

  @override
  Future<Result<CompetitionSeason>> findSeason(SeasonId id) async {
    final found = seasons[id.value];
    return found == null
        ? const Result.err(
            AppError.invariant(
              'competition.season_not_found',
              'Season not found',
            ),
          )
        : Result.ok(found);
  }

  @override
  Future<Result<void>> saveRound(Round round) async {
    rounds[round.id.value] = round;
    return const Result.ok(null);
  }

  @override
  Future<Result<Round>> findRound(RoundId id) async {
    final found = rounds[id.value];
    return found == null
        ? const Result.err(
            AppError.invariant(
              'competition.round_not_found',
              'Round not found',
            ),
          )
        : Result.ok(found);
  }

  @override
  Future<Result<void>> updateRoundStatus(
    Round round,
    RoundStatus expectedPriorStatus,
  ) async {
    final current = rounds[round.id.value];
    if (current == null || current.status != expectedPriorStatus) {
      return const Result.err(
        AppError.invariant(
          'competition.round_transition_conflict',
          'Round is no longer in the expected state',
        ),
      );
    }
    rounds[round.id.value] = round;
    return const Result.ok(null);
  }

  @override
  Future<Result<void>> saveRoundFixture(RoundFixture link) async {
    links.add(link);
    return const Result.ok(null);
  }

  @override
  Future<Result<void>> saveParticipant(Participant participant) async {
    participants.add(participant);
    return const Result.ok(null);
  }

  @override
  Future<Result<Participant?>> findParticipant(
    SeasonId seasonId,
    UserId userId,
  ) async {
    for (final p in participants) {
      if (p.seasonId.value == seasonId.value &&
          p.userId.value == userId.value) {
        return Result.ok(p);
      }
    }
    return const Result.ok(null);
  }

  // Browse reads (BLOCKER FA-1 / DEFECT FA-2): real in-memory implementations
  // over this harness's own store, mirroring the Postgres adapter's filter +
  // order semantics — NOT stubs/throws, since these fakes back the shared
  // route-test harness. An empty result is a legitimate `Ok(<empty list>)`.

  @override
  Future<Result<List<Competition>>> listCompetitions() async {
    // The discoverable catalogue: every PUBLIC competition, ordered by name
    // then id (matches `_listCompetitionsSql` ORDER BY name ASC, id ASC).
    final catalogue =
        [
          for (final c in competitions.values)
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
    // A competition's seasons ordered by their display label then id (matches
    // `_listCompetitionSeasonsSql` ORDER BY label ASC, id ASC). An absent/empty
    // competition is a legitimate empty list — no existence oracle.
    final competitionSeasons =
        [
          for (final s in seasons.values)
            if (s.competitionId.value == competitionId.value) s,
        ]..sort((a, b) {
          final byLabel = a.label.compareTo(b.label);
          return byLabel != 0 ? byLabel : a.id.value.compareTo(b.id.value);
        });
    return Result.ok(competitionSeasons);
  }

  @override
  Future<Result<List<Round>>> listSeasonRounds(SeasonId seasonId) async {
    // A season's rounds ordered by their 1-based sequence (matches
    // `_listSeasonRoundsSql` ORDER BY sequence ASC). Absent/empty season → [].
    final seasonRounds = [
      for (final r in rounds.values)
        if (r.seasonId.value == seasonId.value) r,
    ]..sort((a, b) => a.sequence.compareTo(b.sequence));
    return Result.ok(seasonRounds);
  }

  @override
  Future<Result<List<RoundFixture>>> listRoundFixtures(RoundId roundId) async {
    // The round's fixtures in matchday (display_order) order, tie-broken by
    // fixture id (matches `_listRoundFixturesSql` ORDER BY display_order ASC,
    // fixture_id ASC). Absent/empty round → [].
    final roundLinks =
        [
          for (final link in links)
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

/// A minimal in-memory [PredictionRepository] for the prediction route tests.
///
/// It mirrors the storage contract the use-cases branch on: one prediction per
/// `(round, participant)` (Axiom 4), a `save` that rejects a duplicate with the
/// pivot error `prediction.already_submitted`, an `update` that refreshes the
/// stored forecast + `submitted_at` in place, and `listRoundFixtures` served
/// from an injected link set. Each stored prediction is kept with the instant
/// it was stamped so reads reconstruct a faithful [PredictionView] — exactly
/// what the Postgres adapter does by selecting `submitted_at`. It is NOT a
/// substitute for that adapter's own tests (infrastructure package).
final class InMemoryPredictionRepository implements PredictionRepository {
  /// Round fixtures the use-case reads for the fixture-in-round + completeness
  /// checks; the test seeds this to match the round under test.
  final List<RoundFixture> roundFixtures = [];

  /// Stored predictions keyed by `(roundId, participantId)`, paired with the
  /// submission instant the repository stamped.
  final Map<String, PredictionView> _byRoundParticipant = {};

  static String _key(RoundId roundId, ParticipantId participantId) =>
      '${roundId.value}|${participantId.value}';

  @override
  Future<Result<PredictionView?>> findByRoundAndParticipant(
    RoundId roundId,
    ParticipantId participantId,
  ) async => Result.ok(_byRoundParticipant[_key(roundId, participantId)]);

  @override
  Future<Result<void>> save(Prediction prediction, DateTime submittedAt) async {
    final key = _key(prediction.roundId, prediction.participantId);
    if (_byRoundParticipant.containsKey(key)) {
      // The unique (participant_id, round_id) backstop (Axiom 6): the use-case
      // pivots on this exact code to converge a concurrent duplicate insert.
      return const Result.err(
        AppError.invariant(
          'prediction.already_submitted',
          'A prediction already exists for this participant and round',
        ),
      );
    }
    _byRoundParticipant[key] = PredictionView(
      prediction: prediction,
      submittedAt: submittedAt,
    );
    return const Result.ok(null);
  }

  @override
  Future<Result<void>> update(
    Prediction prediction,
    DateTime submittedAt,
  ) async {
    final key = _key(prediction.roundId, prediction.participantId);
    if (!_byRoundParticipant.containsKey(key)) {
      return const Result.err(
        AppError.invariant('prediction.not_found', 'Prediction not found'),
      );
    }
    _byRoundParticipant[key] = PredictionView(
      prediction: prediction,
      submittedAt: submittedAt,
    );
    return const Result.ok(null);
  }

  @override
  Future<Result<List<PredictionView>>> listByRound(RoundId roundId) async {
    final views =
        [
          for (final view in _byRoundParticipant.values)
            if (view.prediction.roundId.value == roundId.value) view,
        ]..sort((a, b) {
          final byInstant = a.submittedAt.compareTo(b.submittedAt);
          return byInstant != 0
              ? byInstant
              : a.prediction.id.value.compareTo(b.prediction.id.value);
        });
    return Result.ok(views);
  }

  @override
  Future<Result<List<RoundFixture>>> listRoundFixtures(RoundId roundId) async {
    final links = [
      for (final link in roundFixtures)
        if (link.roundId.value == roundId.value) link,
    ];
    return Result.ok(links);
  }
}

/// A minimal in-memory [FixtureResultRepository] for the scoring route tests.
///
/// It mirrors the storage contract the use-cases branch on: `upsert` records or
/// corrects the actual scoreline in place keyed by fixture id (idempotent),
/// `findByFixtures` returns only the fixtures that have a recorded result (a
/// gap is detected by count, never zero-filled — exactly what `ScoreRound`
/// relies on for its `results_incomplete` check). It is NOT a substitute for
/// the Postgres adapter's own tests (infrastructure package).
final class InMemoryFixtureResultRepository implements FixtureResultRepository {
  final Map<String, FixtureResult> _byFixture = {};

  /// The recorded-at instants each fixture was stamped with (audit), so a test
  /// can assert idempotent correction refreshed it.
  final Map<String, DateTime> recordedAt = {};

  /// Number of distinct fixtures currently stored (one row per fixture — an
  /// idempotent correction refreshes in place, never a second row).
  int get count => _byFixture.length;

  @override
  Future<Result<void>> upsert(FixtureResult result, DateTime at) async {
    _byFixture[result.fixture.value] = result;
    recordedAt[result.fixture.value] = at;
    return const Result.ok(null);
  }

  @override
  Future<Result<FixtureResult?>> findByFixture(FixtureRef fixture) async =>
      Result.ok(_byFixture[fixture.value]);

  @override
  Future<Result<List<FixtureResult>>> findByFixtures(
    List<FixtureRef> fixtures,
  ) async {
    final found = <FixtureResult>[
      for (final f in fixtures)
        if (_byFixture[f.value] != null) _byFixture[f.value]!,
    ];
    return Result.ok(found);
  }
}

/// A minimal in-memory [ScoreRepository] for the scoring route tests.
///
/// It mirrors the storage contract the use-cases branch on: `saveRoundScores`
/// upserts each `(round, participant)` in place (idempotent re-score — one row
/// per participant, never a second), and `listByRound` returns the round's
/// scores participant-ordered. It is NOT a substitute for the Postgres
/// adapter's own tests (infrastructure package).
final class InMemoryScoreRepository implements ScoreRepository {
  final Map<String, RoundScore> _byRoundParticipant = {};

  /// Number of distinct `(round, participant)` score rows currently stored
  /// (idempotent re-score upserts in place — never a second row).
  int get count => _byRoundParticipant.length;

  static String _key(RoundId roundId, ParticipantId participantId) =>
      '${roundId.value}|${participantId.value}';

  @override
  Future<Result<void>> saveRoundScores(List<RoundScore> scores) async {
    for (final score in scores) {
      _byRoundParticipant[_key(score.roundId, score.participantId)] = score;
    }
    return const Result.ok(null);
  }

  @override
  Future<Result<List<RoundScore>>> listByRound(RoundId roundId) async {
    final scores = [
      for (final score in _byRoundParticipant.values)
        if (score.roundId.value == roundId.value) score,
    ]..sort((a, b) => a.participantId.value.compareTo(b.participantId.value));
    return Result.ok(scores);
  }
}

/// A minimal in-memory [LedgerRepository] for the ledger route tests.
///
/// It mirrors the storage contract the use-cases branch on: `appendEntries`
/// inserts the batch idempotently on the natural dedupe key
/// `(participant_id, round_id, entry_kind, source_ref)` — an already-present
/// tuple is skipped (never a second crediting row, Axiom 4) and omitted from the
/// returned "actually appended" subset; entries are only ever appended, never
/// mutated or deleted (Axiom 5). `listEntries` returns a participant's stream in
/// the ledger order (occurred-at then id), and `balanceFor` is the pure domain
/// `LedgerBalance.project` over that stream (a projection, never a stored
/// number — Axiom 5). It is NOT a substitute for the Postgres adapter's own
/// tests (infrastructure package).
final class InMemoryLedgerRepository implements LedgerRepository {
  /// Every appended entry, in insertion order. Append-only: nothing is ever
  /// removed or edited.
  final List<PointEntry> entries = [];

  static String _dedupeKey(PointEntry e) =>
      '${e.participantId.value}|${e.roundId.value}|${e.kind.wireValue}'
      '|${e.sourceRef}';

  @override
  Future<Result<List<PointEntry>>> appendEntries(
    List<PointEntry> toAppend,
  ) async {
    final existingKeys = {for (final e in entries) _dedupeKey(e)};
    final appended = <PointEntry>[];
    for (final entry in toAppend) {
      final key = _dedupeKey(entry);
      if (existingKeys.contains(key)) {
        // Deduped skip (idempotent re-post): never a second credit.
        continue;
      }
      existingKeys.add(key);
      entries.add(entry);
      appended.add(entry);
    }
    return Result.ok(List<PointEntry>.unmodifiable(appended));
  }

  @override
  Future<Result<List<PointEntry>>> listEntries(
    ParticipantId participantId,
  ) async {
    final own =
        [
          for (final e in entries)
            if (e.participantId.value == participantId.value) e,
        ]..sort((a, b) {
          final byInstant = a.occurredAt.compareTo(b.occurredAt);
          return byInstant != 0 ? byInstant : a.id.value.compareTo(b.id.value);
        });
    return Result.ok(List<PointEntry>.unmodifiable(own));
  }

  @override
  Future<Result<LedgerBalance>> balanceFor(ParticipantId participantId) async {
    final listed = await listEntries(participantId);
    if (listed is Err<List<PointEntry>>) {
      return Result.err(listed.error);
    }
    return LedgerBalance.project(
      participantId: participantId,
      entries: (listed as Ok<List<PointEntry>>).value,
    );
  }
}

/// A minimal in-memory [ParticipantReader] for the ledger read route tests.
///
/// It resolves a participant by its own id (the narrow read port the Ledger
/// slice owns, since the frozen CompetitionRepository has no by-id lookup),
/// returning `Ok(null)` for an unknown id so the use-case reports it as
/// not-found without leaking existence. It is NOT a substitute for the Postgres
/// adapter's own tests (infrastructure package).
final class InMemoryParticipantReader implements ParticipantReader {
  final Map<String, Participant> _byId = {};

  /// Registers [participant] so `findParticipantById` resolves it.
  void add(Participant participant) {
    _byId[participant.id.value] = participant;
  }

  @override
  Future<Result<Participant?>> findParticipantById(ParticipantId id) async =>
      Result.ok(_byId[id.value]);
}

/// A minimal in-memory [LeaderboardRepository] for the leaderboard route test.
///
/// It returns a per-season set of UNRANKED [LeaderboardEntry] projections the
/// test seeds (mirroring what the Postgres VIEW adapter produces: one entry per
/// season participant, each carrying a signed total, movement count, and
/// joinedAt tie-break key — ranking is the pure domain's job in the use-case).
/// An unseeded season yields an empty board. It is NOT a substitute for the
/// Postgres adapter's own tests (infrastructure package).
final class InMemoryLeaderboardRepository implements LeaderboardRepository {
  final Map<String, List<LeaderboardEntry>> _bySeason = {};

  /// Seeds the unranked [entries] returned for [seasonId].
  void seed(String seasonId, List<LeaderboardEntry> entries) {
    _bySeason[seasonId] = entries;
  }

  @override
  Future<Result<List<LeaderboardEntry>>> seasonStandings(
    SeasonId seasonId,
  ) async => Result.ok(_bySeason[seasonId.value] ?? const <LeaderboardEntry>[]);
}

/// A [RulesetProvider] returning a fixed valid snapshot, so OpenRound tests need
/// no Scoring context (a later phase).
final class FixedRulesetProvider implements RulesetProvider {
  const FixedRulesetProvider();

  @override
  Future<Result<RulesetSnapshot>> currentSnapshotFor(FormatType format) async =>
      RulesetSnapshot.create(payload: const {'exact': 3}, rulesetVersion: 1);
}

/// Deterministic [IdGenerator] yielding a scripted sequence of ids.
final class ScriptedIdGenerator implements IdGenerator {
  ScriptedIdGenerator(this._ids);
  final List<String> _ids;
  int _i = 0;

  @override
  String newUuid() {
    final id = _i < _ids.length ? _ids[_i] : _ids.last;
    _i++;
    return id;
  }
}

/// A fixed [Clock].
final class FixedClock implements Clock {
  const FixedClock(this.now);
  final DateTime now;

  @override
  DateTime nowUtc() => now;
}

/// A minimal in-memory [GroupRepository] for the Groups route tests, mirroring
/// the observable storage contract the real `PostgresGroupRepository` honours
/// (and the application-layer `InMemoryGroupRepository` fake): atomic
/// group+owner create, `(groupId, userId)` membership uniqueness surfacing
/// `group.already_member`, current-invite-code resolution (a rotated code no
/// longer resolves), joinedAt-ascending roster. It is NOT a substitute for the
/// adapter's own tests (infrastructure package). A scripted transient failure
/// proves the route's 503 mapping.
final class InMemoryGroupRepository implements GroupRepository {
  final Map<String, Group> groups = {};
  final List<GroupMembership> memberships = [];

  AppError? _scriptedFailure;

  /// Scripts the *next* call to fail with [error], then clears the script.
  void failNextWith(AppError error) => _scriptedFailure = error;

  AppError? _takeFailure() {
    final f = _scriptedFailure;
    _scriptedFailure = null;
    return f;
  }

  /// Seeds a group directly (tests needing a pre-existing group).
  void seedGroup(Group group) => groups[group.id.value] = group;

  /// Seeds a membership directly.
  void seedMembership(GroupMembership membership) =>
      memberships.add(membership);

  @override
  Future<Result<void>> createGroupWithOwner(
    Group group,
    GroupMembership ownerMembership,
  ) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    if (groups.containsKey(group.id.value) ||
        groups.values.any(
          (g) => g.inviteCode.value == group.inviteCode.value,
        )) {
      return const Result.err(
        AppError.invariant(
          'group.invite_code_conflict',
          'A group with that id or invite code already exists',
        ),
      );
    }
    groups[group.id.value] = group;
    memberships.add(ownerMembership);
    return const Result.ok(null);
  }

  @override
  Future<Result<Group?>> findGroup(GroupId id) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    return Result.ok(groups[id.value]);
  }

  @override
  Future<Result<Group?>> findByInviteCode(InviteCode inviteCode) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    for (final g in groups.values) {
      if (g.inviteCode.value == inviteCode.value) {
        return Result.ok(g);
      }
    }
    return const Result.ok(null);
  }

  @override
  Future<Result<void>> updateGroup(Group group) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    final collision = groups.values.any(
      (g) =>
          g.id.value != group.id.value &&
          g.inviteCode.value == group.inviteCode.value,
    );
    if (collision) {
      return const Result.err(
        AppError.invariant(
          'group.invite_code_conflict',
          'That invite code collides with another group',
        ),
      );
    }
    groups[group.id.value] = group;
    return const Result.ok(null);
  }

  @override
  Future<Result<void>> saveMembership(GroupMembership membership) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    final dup = memberships.any(
      (m) =>
          m.groupId.value == membership.groupId.value &&
          m.userId.value == membership.userId.value,
    );
    if (dup) {
      return const Result.err(
        AppError.invariant(
          'group.already_member',
          'The user is already a member of the group',
        ),
      );
    }
    memberships.add(membership);
    return const Result.ok(null);
  }

  @override
  Future<Result<GroupMembership?>> findMembership(
    GroupId groupId,
    UserId userId,
  ) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    for (final m in memberships) {
      if (m.groupId.value == groupId.value && m.userId.value == userId.value) {
        return Result.ok(m);
      }
    }
    return const Result.ok(null);
  }

  @override
  Future<Result<List<GroupMembership>>> listMemberships(GroupId groupId) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    final list =
        memberships.where((m) => m.groupId.value == groupId.value).toList()
          ..sort((a, b) => a.joinedAt.compareTo(b.joinedAt));
    return Result.ok(List<GroupMembership>.unmodifiable(list));
  }
}

/// A minimal in-memory [GroupStandingsReader] for the group-leaderboard route
/// test: returns the unranked group∩season standing entries (member userId +
/// unranked season entry) seeded per `(groupId, seasonId)`; the list order is
/// unspecified (the use-case ranks it). Never throws; a scripted transient
/// failure proves propagation.
final class InMemoryGroupStandingsReader implements GroupStandingsReader {
  final Map<String, List<GroupStandingEntry>> _byKey = {};

  AppError? _scriptedFailure;

  /// Scripts the *next* call to fail with [error], then clears the script.
  void failNextWith(AppError error) => _scriptedFailure = error;

  static String _key(String groupId, String seasonId) => '$groupId::$seasonId';

  /// Seeds the unranked standing entries for a `(group, season)` pair.
  void seed(
    String groupId,
    String seasonId,
    List<GroupStandingEntry> entries,
  ) => _byKey[_key(groupId, seasonId)] = List<GroupStandingEntry>.of(entries);

  @override
  Future<Result<List<GroupStandingEntry>>> groupSeasonStandings({
    required GroupId groupId,
    required SeasonId seasonId,
  }) async {
    final f = _scriptedFailure;
    _scriptedFailure = null;
    if (f != null) return Result.err(f);
    return Result.ok(
      List<GroupStandingEntry>.unmodifiable(
        _byKey[_key(groupId.value, seasonId.value)] ?? const [],
      ),
    );
  }
}

/// A minimal in-memory [ReactionRepository] for the Social route tests. It
/// stores at most one reaction per `(groupId, roundId, userId)` — the physical
/// "one live reaction per member per round-result" (Social decision #2) — so
/// `upsertReaction` is a genuine upsert (a swap replaces in place, never a
/// second row) and `removeReaction` reports whether a row was actually removed
/// (idempotent). `listReactionsForRound` returns the `(group, round)` reactions
/// in reactedAt-ascending order. Never throws; a scripted transient failure
/// proves propagation.
final class InMemoryReactionRepository implements ReactionRepository {
  final List<Reaction> reactions = [];

  AppError? _scriptedFailure;

  /// Scripts the *next* call to fail with [error], then clears the script.
  void failNextWith(AppError error) => _scriptedFailure = error;

  AppError? _takeFailure() {
    final f = _scriptedFailure;
    _scriptedFailure = null;
    return f;
  }

  /// Seeds a reaction directly (tests needing a pre-existing reaction).
  void seed(Reaction reaction) => reactions.add(reaction);

  static bool _sameKey(Reaction r, GroupId g, RoundId round, UserId u) =>
      r.groupId.value == g.value &&
      r.roundId.value == round.value &&
      r.userId.value == u.value;

  @override
  Future<Result<void>> upsertReaction(Reaction reaction) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    final idx = reactions.indexWhere(
      (r) => _sameKey(r, reaction.groupId, reaction.roundId, reaction.userId),
    );
    if (idx >= 0) {
      // Swap in place — same key, never a second row (decision #2).
      reactions[idx] = reaction;
    } else {
      reactions.add(reaction);
    }
    return const Result.ok(null);
  }

  @override
  Future<Result<Reaction?>> findReaction(
    GroupId groupId,
    RoundId roundId,
    UserId userId,
  ) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    for (final r in reactions) {
      if (_sameKey(r, groupId, roundId, userId)) {
        return Result.ok(r);
      }
    }
    return const Result.ok(null);
  }

  @override
  Future<Result<List<Reaction>>> listReactionsForRound(
    GroupId groupId,
    RoundId roundId,
  ) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    final list =
        reactions
            .where(
              (r) =>
                  r.groupId.value == groupId.value &&
                  r.roundId.value == roundId.value,
            )
            .toList()
          ..sort((a, b) => a.reactedAt.compareTo(b.reactedAt));
    return Result.ok(List<Reaction>.unmodifiable(list));
  }

  @override
  Future<Result<bool>> removeReaction(
    GroupId groupId,
    RoundId roundId,
    UserId userId,
  ) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    final before = reactions.length;
    reactions.removeWhere((r) => _sameKey(r, groupId, roundId, userId));
    return Result.ok(reactions.length != before);
  }
}

/// A minimal in-memory [ActivityFeedReader] for the Social feed route test:
/// returns the events seeded per group, newest-first, capped at the requested
/// limit, and records the last requested limit so a test can assert the
/// use-case's clamp reached the reader. Never throws; a scripted transient
/// failure proves propagation.
final class InMemoryActivityFeedReader implements ActivityFeedReader {
  final Map<String, List<ActivityEvent>> _byGroup = {};

  /// The limit the reader was last asked for (proves the use-case's clamp).
  int? lastLimit;

  AppError? _scriptedFailure;

  /// Scripts the *next* call to fail with [error], then clears the script.
  void failNextWith(AppError error) => _scriptedFailure = error;

  /// Seeds the events for a group (any order; the reader returns them
  /// newest-first).
  void seed(String groupId, List<ActivityEvent> events) =>
      _byGroup[groupId] = List<ActivityEvent>.of(events);

  @override
  Future<Result<List<ActivityEvent>>> groupActivityFeed({
    required GroupId groupId,
    required int limit,
  }) async {
    lastLimit = limit;
    final f = _scriptedFailure;
    _scriptedFailure = null;
    if (f != null) return Result.err(f);
    final all = List<ActivityEvent>.of(_byGroup[groupId.value] ?? const [])
      ..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
    final capped = all.length > limit ? all.sublist(0, limit) : all;
    return Result.ok(List<ActivityEvent>.unmodifiable(capped));
  }
}

/// Builds a stored [Reaction] (rehydrated, typing only — no validation branch).
Reaction storedReaction({
  String id = kReactionId,
  String groupId = kGroupId,
  String roundId = kRoundId,
  required String userId,
  ReactionKind emoji = ReactionKind.fire,
  DateTime? reactedAt,
}) => Reaction.fromStored(
  id: (ReactionId.tryParse(id) as Ok<ReactionId>).value,
  groupId: GroupId(groupId),
  roundId: RoundId(roundId),
  userId: UserId(userId),
  emoji: ReactionEmoji.of(emoji),
  reactedAt: reactedAt ?? DateTime.utc(2026, 7, 12, 9),
);

/// A fake [InviteCodeGenerator] yielding a scripted sequence of well-formed
/// codes (each exactly `InviteCode.codeLength` chars over the alphabet), so a
/// create/regenerate route test can pin the generated code deterministically.
final class ScriptedInviteCodeGenerator implements InviteCodeGenerator {
  ScriptedInviteCodeGenerator(this._codes);
  final List<String> _codes;
  int _i = 0;

  @override
  InviteCode newCode() {
    final raw = _i < _codes.length ? _codes[_i] : _codes.last;
    _i++;
    return (InviteCode.tryParse(raw) as Ok<InviteCode>).value;
  }
}

/// Builds a stored [Group] (rehydrated, typing only — no validation branch).
Group storedGroup({
  String id = kGroupId,
  String ownerId = kOwnerUserId,
  String name = 'The Circle',
  String inviteCode = kInviteCode,
  DateTime? createdAt,
}) => Group.fromStored(
  id: GroupId(id),
  ownerId: UserId(ownerId),
  name: name,
  inviteCode: (InviteCode.tryParse(inviteCode) as Ok<InviteCode>).value,
  createdAt: createdAt ?? DateTime.utc(2026, 7, 1),
);

/// Builds a stored [GroupMembership].
GroupMembership storedMembership({
  required String id,
  required String userId,
  String groupId = kGroupId,
  GroupRole role = GroupRole.member,
  DateTime? joinedAt,
}) => GroupMembership.fromStored(
  id: GroupMembershipId(id),
  groupId: GroupId(groupId),
  userId: UserId(userId),
  role: role,
  joinedAt: joinedAt ?? DateTime.utc(2026, 7, 1),
);

/// Builds an unranked [GroupStandingEntry] (member userId + season projection).
GroupStandingEntry groupStanding({
  required String userId,
  required String participantId,
  required int totalPoints,
  int entryCount = 1,
  DateTime? joinedAt,
}) => GroupStandingEntry(
  userId: UserId(userId),
  entry:
      (LeaderboardEntry.projected(
                participantId: ParticipantId(participantId),
                totalPoints: totalPoints,
                entryCount: entryCount,
                joinedAt: joinedAt ?? DateTime.utc(2026, 7, 1, 9),
              )
              as Ok<LeaderboardEntry>)
          .value,
);

/// A principal for the group owner (canonical owner user id).
AuthenticatedUser ownerPrincipal() => const AuthenticatedUser(
  userId: UserId(kOwnerUserId),
  role: PlatformRole.user,
);

/// A principal for a non-owner member (canonical member user id).
AuthenticatedUser memberPrincipal() => const AuthenticatedUser(
  userId: UserId(kMemberUserId),
  role: PlatformRole.user,
);

/// A principal for a user who is not a member of the group.
AuthenticatedUser nonMemberPrincipal() => const AuthenticatedUser(
  userId: UserId(kNonMemberUserId),
  role: PlatformRole.user,
);

class MockRequestContext extends Mock implements RequestContext {}

class MockRequest extends Mock implements Request {}

AuthenticatedUser adminPrincipal() =>
    const AuthenticatedUser(userId: UserId(kAdminId), role: PlatformRole.admin);

AuthenticatedUser userPrincipal() =>
    const AuthenticatedUser(userId: UserId(kUserId), role: PlatformRole.user);

/// Builds a request context with a body of [body] (JSON-encoded), a [method],
/// a [principal], and a real composition [root].
///
/// [queryParameters] populate `context.request.uri.queryParameters` — needed by
/// routes that read an optional query hint (e.g. `GET /groups/{id}/feed?limit=`).
/// The `uri` is always stubbed (default: `/` with no query) so a route may read
/// it unconditionally without a `MissingStubError`.
MockRequestContext wireContext({
  required CompositionRoot root,
  required AuthenticatedUser principal,
  Object? body,
  HttpMethod method = HttpMethod.post,
  Map<String, String> queryParameters = const {},
}) {
  final request = MockRequest();
  when(() => request.method).thenReturn(method);
  when(
    request.body,
  ).thenAnswer((_) async => body == null ? '' : jsonEncode(body));
  when(() => request.uri).thenReturn(
    Uri(
      path: '/',
      queryParameters: queryParameters.isEmpty ? null : queryParameters,
    ),
  );

  final rootFuture = Future<CompositionRoot>.value(root);
  final context = MockRequestContext();
  when(() => context.request).thenReturn(request);
  when(
    () => context.read<Future<CompositionRoot>>(),
  ).thenAnswer((_) => rootFuture);
  when(() => context.read<AuthenticatedUser>()).thenReturn(principal);
  return context;
}

/// Decodes a JSON response body to a `Map<String, Object?>`.
Future<Map<String, Object?>> decodeBody(Response response) async {
  final decoded = await response.json() as Map<Object?, Object?>;
  return decoded.cast<String, Object?>();
}

/// A minimal in-memory [NotificationRepository] for the Notifications route
/// tests: recipient-scoped self-read/self-mark of the ONE stored Tier-3 surface
/// (decision #4 — a caller only ever touches their own rows; a foreign/unknown
/// id is invisible, `Ok(null)`, so the use-case refuses it identically as
/// `notification.not_found` with no existence oracle). It is NOT a substitute
/// for the Postgres adapter's own tests — those live in the infrastructure
/// package. Never throws; a scripted transient failure proves propagation.
final class InMemoryNotificationRepository implements NotificationRepository {
  final List<Notification> notifications = [];

  AppError? _scriptedFailure;

  /// The limit the repository was last asked for (proves the use-case's clamp).
  int? lastLimit;

  /// Scripts the *next* call to fail with [error], then clears the script.
  void failNextWith(AppError error) => _scriptedFailure = error;

  AppError? _takeFailure() {
    final f = _scriptedFailure;
    _scriptedFailure = null;
    return f;
  }

  /// Seeds a notification directly (tests needing pre-existing rows).
  void seed(Notification notification) => notifications.add(notification);

  int _indexOf(NotificationId id, UserId recipientId) =>
      notifications.indexWhere(
        (n) =>
            n.id.value == id.value && n.recipientId.value == recipientId.value,
      );

  @override
  Future<Result<bool>> createIfAbsent(Notification notification) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    final exists = notifications.any(
      (n) =>
          n.recipientId.value == notification.recipientId.value &&
          n.kind == notification.kind &&
          n.subject.dedupeRef == notification.subject.dedupeRef,
    );
    if (exists) return const Result.ok(false);
    notifications.add(notification);
    return const Result.ok(true);
  }

  @override
  Future<Result<List<Notification>>> listForRecipient(
    UserId recipientId, {
    required int limit,
  }) async {
    lastLimit = limit;
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    // Recipient-scoped, newest-first (createdAt desc, then id desc as a stable
    // tiebreak — the adapter's contract), truncated to the clamped limit.
    final own =
        notifications
            .where((n) => n.recipientId.value == recipientId.value)
            .toList()
          ..sort((a, b) {
            final byCreated = b.createdAt.compareTo(a.createdAt);
            if (byCreated != 0) return byCreated;
            return b.id.value.compareTo(a.id.value);
          });
    final capped = own.length > limit ? own.sublist(0, limit) : own;
    return Result.ok(List<Notification>.unmodifiable(capped));
  }

  @override
  Future<Result<Notification?>> findForRecipient(
    NotificationId id,
    UserId recipientId,
  ) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    final idx = _indexOf(id, recipientId);
    return Result.ok(idx >= 0 ? notifications[idx] : null);
  }

  @override
  Future<Result<bool?>> markRead(
    NotificationId id,
    UserId recipientId,
    DateTime readAt,
  ) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    final idx = _indexOf(id, recipientId);
    // Foreign or absent → invisible to this recipient (no existence oracle).
    if (idx < 0) return const Result.ok(null);
    final current = notifications[idx];
    // Already read → idempotent no-op that preserves the original timestamp.
    if (current.isRead) return const Result.ok(false);
    final marked = current.markRead(readAt);
    if (marked is Err<Notification>) return Result.err(marked.error);
    notifications[idx] = (marked as Ok<Notification>).value;
    return const Result.ok(true);
  }

  @override
  Future<Result<int>> unreadCount(UserId recipientId) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    final count = notifications
        .where((n) => n.recipientId.value == recipientId.value && !n.isRead)
        .length;
    return Result.ok(count);
  }
}

/// Builds a stored `roundScored` [Notification] (rehydrated, typing only — no
/// validation branch), the simplest kind for recipient-scoped read/mark tests.
Notification storedNotification({
  String id = kNotificationId,
  required String recipientId,
  String roundId = kRoundId,
  DateTime? createdAt,
  DateTime? readAt,
}) => Notification.fromStored(
  id: (NotificationId.tryParse(id) as Ok<NotificationId>).value,
  recipientId: UserId(recipientId),
  kind: NotificationKind.roundScored,
  subject: NotificationSubject.roundScored(roundId: RoundId(roundId)),
  createdAt: createdAt ?? DateTime.utc(2026, 7, 12, 9),
  readAt: readAt,
);

/// A minimal in-memory [UserAdminRepository] for the Admin route tests: resolves
/// a target [User] by id and persists a status-only transition
/// (`User.suspend()`/`reinstate()` — the ONLY field the admin surface mutates).
/// An unknown id is `Ok(null)` so the use-case reports `admin.user_not_found`
/// without leaking existence. It is NOT a substitute for the Postgres adapter's
/// own tests (infrastructure package). Never throws; a scripted transient
/// failure proves the route's 503 mapping.
final class InMemoryUserAdminRepository implements UserAdminRepository {
  final Map<String, User> users = {};

  AppError? _scriptedFailure;

  /// Scripts the *next* call to fail with [error], then clears the script.
  void failNextWith(AppError error) => _scriptedFailure = error;

  AppError? _takeFailure() {
    final f = _scriptedFailure;
    _scriptedFailure = null;
    return f;
  }

  /// Seeds a user directly (tests needing a pre-existing target).
  void seed(User user) => users[user.id.value] = user;

  @override
  Future<Result<User?>> findUserById(UserId id) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    return Result.ok(users[id.value]);
  }

  @override
  Future<Result<User>> updateUser(User user) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    users[user.id.value] = user;
    return Result.ok(user);
  }
}

/// A minimal in-memory [AuditLogRepository] for the Admin route tests: the
/// append-only admin trail. `append` records the immutable entry (never mutated
/// or deleted); `list` returns the trail newest-first (occurredAt desc, then id
/// desc as a stable tie-break — the adapter's contract) truncated to the clamped
/// limit, and records the last requested limit so a test can assert the
/// use-case's clamp reached the repository. It is NOT a substitute for the
/// Postgres adapter's own tests (infrastructure package). Never throws; a
/// scripted transient failure proves the route's 503 mapping.
final class InMemoryAuditLogRepository implements AuditLogRepository {
  final List<AuditEntry> entries = [];

  AppError? _scriptedFailure;

  /// The limit the repository was last asked for (proves the use-case's clamp).
  int? lastRequestedLimit;

  /// Scripts the *next* call to fail with [error], then clears the script.
  void failNextWith(AppError error) => _scriptedFailure = error;

  AppError? _takeFailure() {
    final f = _scriptedFailure;
    _scriptedFailure = null;
    return f;
  }

  /// Seeds an entry directly (tests needing a pre-existing trail).
  void seed(AuditEntry entry) => entries.add(entry);

  @override
  Future<Result<AuditEntry>> append(AuditEntry entry) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    entries.add(entry);
    return Result.ok(entry);
  }

  @override
  Future<Result<List<AuditEntry>>> list({required int limit}) async {
    lastRequestedLimit = limit;
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    final sorted = List<AuditEntry>.of(entries)
      ..sort((a, b) {
        final byInstant = b.occurredAt.compareTo(a.occurredAt);
        if (byInstant != 0) return byInstant;
        return b.id.value.compareTo(a.id.value);
      });
    final capped = sorted.length > limit ? sorted.sublist(0, limit) : sorted;
    return Result.ok(List<AuditEntry>.unmodifiable(capped));
  }
}

/// Builds a stored [User] (rehydrated via the plain const ctor — typing only,
/// no validation branch), the target of an admin sanction.
User storedUser({
  String id = kTargetUserId,
  String? email = 'target@example.com',
  PlatformRole role = PlatformRole.user,
  UserStatus status = UserStatus.active,
}) => User(id: UserId(id), email: email, role: role, status: status);

/// Builds a stored [AuditEntry] (rehydrated, typing only — no validation
/// branch), an element of the append-only admin trail.
AuditEntry storedAuditEntry({
  String id = kAuditEntryId,
  String actorId = kAdminId,
  AuditAction action = AuditAction.userSuspended,
  String targetRef = kTargetUserId,
  String? reason = 'abuse',
  DateTime? occurredAt,
}) => AuditEntry.fromStored(
  id: (AuditEntryId.tryParse(id) as Ok<AuditEntryId>).value,
  actorId: UserId(actorId),
  action: action,
  targetRef: targetRef,
  reason: reason,
  occurredAt: occurredAt ?? DateTime.utc(2026, 7, 13, 9),
);
