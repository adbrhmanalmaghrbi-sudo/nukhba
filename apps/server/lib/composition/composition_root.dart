import 'dart:io';

import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:infrastructure/infrastructure.dart';
import 'package:meta/meta.dart';
import 'package:shared/shared.dart';

/// The single place where the dependency graph is wired (Application ADR,
/// Section 13). Nothing else in the server constructs infrastructure directly.
///
/// This is the ONLY component permitted to depend on `infrastructure`
/// (Application ADR, Section 8: nothing depends on Infrastructure except the
/// composition root).
final class CompositionRoot {
  CompositionRoot._({
    required PostgresConnection connection,
    required JwksClient jwksClient,
    required this.checkHealth,
    required this.authenticateRequest,
    required this.getCurrentUser,
    required this.createCompetition,
    required this.startSeason,
    required this.openRound,
    required this.lockRound,
    required this.linkFixtureToRound,
    required this.joinCompetition,
    required this.getCompetition,
    required this.getRound,
    required this.listCompetitions,
    required this.listCompetitionSeasons,
    required this.listSeasonRounds,
    required this.listRoundFixtures,
    required this.submitPrediction,
    required this.getMyPrediction,
    required this.listRoundPredictions,
    required this.recordFixtureResult,
    required this.scoreRound,
    required this.getRoundScores,
    required this.postRoundToLedger,
    required this.readParticipantLedger,
    required this.getSeasonLeaderboard,
    required this.createGroup,
    required this.getGroup,
    required this.joinGroupByInvite,
    required this.renameGroup,
    required this.regenerateInvite,
    required this.listGroupMembers,
    required this.getGroupLeaderboard,
    required this.reactToRound,
    required this.removeReaction,
    required this.listRoundReactions,
    required this.getGroupActivityFeed,
    required this.listMyNotifications,
    required this.getUnreadCount,
    required this.markNotificationRead,
    required this.suspendUser,
    required this.reinstateUser,
    required this.listAuditLog,
    required this.viewParticipantLedger,
  }) : _connection = connection,
       _jwksClient = jwksClient;

  // NOTE: the fields [submitPrediction], [getMyPrediction] and
  // [listRoundPredictions] are declared below alongside the competition
  // use-cases; the private constructor above already requires them so the
  // production graph must wire them, while [forTesting] supplies loud "absent"
  // stand-ins for any prediction slice a given route test does not exercise.

  /// Test-only constructor: builds a root around already-assembled use-cases
  /// (typically wired to in-memory fakes), without opening any real
  /// infrastructure.
  ///
  /// This preserves encapsulation — the production graph is still built solely
  /// via [bootstrap] — while letting route tests exercise the *real* wiring
  /// (`context.read<Future<CompositionRoot>>()` -> `root.<useCase>()`) against
  /// controllable use-cases. We deliberately avoid `implements CompositionRoot`,
  /// which is impossible here because the class is `final`.
  ///
  /// [dispose] is a no-op for roots created this way, since no connection or
  /// JWKS client was opened.
  ///
  /// Every use-case is optional: a route test wires only the slice it
  /// exercises (e.g. the `/health` test provides just [checkHealth]; the `/me`
  /// test provides [authenticateRequest] + [getCurrentUser]). Any use-case not
  /// supplied is replaced by an "absent" stand-in that throws a clear
  /// [StateError] if invoked, so a test that reaches an unwired slice fails
  /// loudly instead of dereferencing null.
  @visibleForTesting
  CompositionRoot.forTesting({
    CheckHealth? checkHealth,
    AuthenticateRequest? authenticateRequest,
    GetCurrentUser? getCurrentUser,
    CreateCompetition? createCompetition,
    StartSeason? startSeason,
    OpenRound? openRound,
    LockRound? lockRound,
    LinkFixtureToRound? linkFixtureToRound,
    JoinCompetition? joinCompetition,
    GetCompetition? getCompetition,
    GetRound? getRound,
    ListCompetitions? listCompetitions,
    ListCompetitionSeasons? listCompetitionSeasons,
    ListSeasonRounds? listSeasonRounds,
    ListRoundFixtures? listRoundFixtures,
    SubmitPrediction? submitPrediction,
    GetMyPrediction? getMyPrediction,
    ListRoundPredictions? listRoundPredictions,
    RecordFixtureResult? recordFixtureResult,
    ScoreRound? scoreRound,
    GetRoundScores? getRoundScores,
    PostRoundToLedger? postRoundToLedger,
    ReadParticipantLedger? readParticipantLedger,
    GetSeasonLeaderboard? getSeasonLeaderboard,
    CreateGroup? createGroup,
    GetGroup? getGroup,
    JoinGroupByInvite? joinGroupByInvite,
    RenameGroup? renameGroup,
    RegenerateInvite? regenerateInvite,
    ListGroupMembers? listGroupMembers,
    GetGroupLeaderboard? getGroupLeaderboard,
    ReactToRound? reactToRound,
    RemoveReaction? removeReaction,
    ListRoundReactions? listRoundReactions,
    GetGroupActivityFeed? getGroupActivityFeed,
    ListMyNotifications? listMyNotifications,
    GetUnreadCount? getUnreadCount,
    MarkNotificationRead? markNotificationRead,
    SuspendUser? suspendUser,
    ReinstateUser? reinstateUser,
    ListAuditLog? listAuditLog,
    ViewParticipantLedger? viewParticipantLedger,
  }) : checkHealth = checkHealth ?? _absentCheckHealth(),
       authenticateRequest =
           authenticateRequest ?? _absentAuthenticateRequest(),
       getCurrentUser = getCurrentUser ?? _absentGetCurrentUser(),
       createCompetition = createCompetition ?? _absentCreateCompetition(),
       startSeason = startSeason ?? _absentStartSeason(),
       openRound = openRound ?? _absentOpenRound(),
       lockRound = lockRound ?? _absentLockRound(),
       linkFixtureToRound = linkFixtureToRound ?? _absentLinkFixtureToRound(),
       joinCompetition = joinCompetition ?? _absentJoinCompetition(),
       getCompetition = getCompetition ?? _absentGetCompetition(),
       getRound = getRound ?? _absentGetRound(),
       listCompetitions = listCompetitions ?? _absentListCompetitions(),
       listCompetitionSeasons =
           listCompetitionSeasons ?? _absentListCompetitionSeasons(),
       listSeasonRounds = listSeasonRounds ?? _absentListSeasonRounds(),
       listRoundFixtures = listRoundFixtures ?? _absentListRoundFixtures(),
       submitPrediction = submitPrediction ?? _absentSubmitPrediction(),
       getMyPrediction = getMyPrediction ?? _absentGetMyPrediction(),
       listRoundPredictions =
           listRoundPredictions ?? _absentListRoundPredictions(),
       recordFixtureResult =
           recordFixtureResult ?? _absentRecordFixtureResult(),
       scoreRound = scoreRound ?? _absentScoreRound(),
       getRoundScores = getRoundScores ?? _absentGetRoundScores(),
       postRoundToLedger = postRoundToLedger ?? _absentPostRoundToLedger(),
       readParticipantLedger =
           readParticipantLedger ?? _absentReadParticipantLedger(),
       getSeasonLeaderboard =
           getSeasonLeaderboard ?? _absentGetSeasonLeaderboard(),
       createGroup = createGroup ?? _absentCreateGroup(),
       getGroup = getGroup ?? _absentGetGroup(),
       joinGroupByInvite = joinGroupByInvite ?? _absentJoinGroupByInvite(),
       renameGroup = renameGroup ?? _absentRenameGroup(),
       regenerateInvite = regenerateInvite ?? _absentRegenerateInvite(),
       listGroupMembers = listGroupMembers ?? _absentListGroupMembers(),
       getGroupLeaderboard =
           getGroupLeaderboard ?? _absentGetGroupLeaderboard(),
       reactToRound = reactToRound ?? _absentReactToRound(),
       removeReaction = removeReaction ?? _absentRemoveReaction(),
       listRoundReactions = listRoundReactions ?? _absentListRoundReactions(),
       getGroupActivityFeed =
           getGroupActivityFeed ?? _absentGetGroupActivityFeed(),
       listMyNotifications =
           listMyNotifications ?? _absentListMyNotifications(),
       getUnreadCount = getUnreadCount ?? _absentGetUnreadCount(),
       markNotificationRead =
           markNotificationRead ?? _absentMarkNotificationRead(),
       suspendUser = suspendUser ?? _absentSuspendUser(),
       reinstateUser = reinstateUser ?? _absentReinstateUser(),
       listAuditLog = listAuditLog ?? _absentListAuditLog(),
       viewParticipantLedger =
           viewParticipantLedger ?? _absentViewParticipantLedger(),
       _connection = null,
       _jwksClient = null;

  /// Builds a [CheckHealth] wired to a repository that fails if pinged, so an
  /// unwired health slice surfaces immediately in a test.
  static CheckHealth _absentCheckHealth() =>
      CheckHealth(_UnwiredHealthRepository());

  /// Builds an [AuthenticateRequest] over a verifier that throws if invoked.
  static AuthenticateRequest _absentAuthenticateRequest() =>
      AuthenticateRequest(_UnwiredTokenVerifier());

  /// Builds a [GetCurrentUser] over a directory that throws if invoked.
  static GetCurrentUser _absentGetCurrentUser() =>
      GetCurrentUser(_UnwiredUserDirectory());

  /// A single throwing repository backing every "absent" competition use-case,
  /// so a test that reaches an unwired competition slice fails loudly.
  static final CompetitionRepository _unwiredCompetitionRepository =
      _UnwiredCompetitionRepository();

  static final RulesetProvider _unwiredRulesetProvider =
      _UnwiredRulesetProvider();

  static final IdGenerator _unwiredIdGenerator = _UnwiredIdGenerator();

  static final Clock _unwiredClock = _UnwiredClock();

  static CreateCompetition _absentCreateCompetition() => CreateCompetition(
    repository: _unwiredCompetitionRepository,
    idGenerator: _unwiredIdGenerator,
  );

  static StartSeason _absentStartSeason() => StartSeason(
    repository: _unwiredCompetitionRepository,
    idGenerator: _unwiredIdGenerator,
  );

  static OpenRound _absentOpenRound() => OpenRound(
    repository: _unwiredCompetitionRepository,
    rulesetProvider: _unwiredRulesetProvider,
    idGenerator: _unwiredIdGenerator,
  );

  static LockRound _absentLockRound() =>
      LockRound(_unwiredCompetitionRepository);

  static LinkFixtureToRound _absentLinkFixtureToRound() =>
      LinkFixtureToRound(_unwiredCompetitionRepository);

  static JoinCompetition _absentJoinCompetition() => JoinCompetition(
    repository: _unwiredCompetitionRepository,
    idGenerator: _unwiredIdGenerator,
    clock: _unwiredClock,
  );

  // Read-only Competition-browse query use-cases (BLOCKER FA-1). Each stand-in
  // is wired to the same loud throwing repository as the write use-cases above,
  // so a route test that reaches an unwired browse slice fails loudly.
  static GetCompetition _absentGetCompetition() =>
      GetCompetition(repository: _unwiredCompetitionRepository);

  static GetRound _absentGetRound() =>
      GetRound(repository: _unwiredCompetitionRepository);

  static ListCompetitions _absentListCompetitions() =>
      ListCompetitions(repository: _unwiredCompetitionRepository);

  static ListCompetitionSeasons _absentListCompetitionSeasons() =>
      ListCompetitionSeasons(repository: _unwiredCompetitionRepository);

  static ListSeasonRounds _absentListSeasonRounds() =>
      ListSeasonRounds(repository: _unwiredCompetitionRepository);

  static ListRoundFixtures _absentListRoundFixtures() =>
      ListRoundFixtures(repository: _unwiredCompetitionRepository);

  /// A single throwing repository backing every "absent" prediction use-case,
  /// so a test that reaches an unwired prediction slice fails loudly instead of
  /// touching a real database.
  static final PredictionRepository _unwiredPredictionRepository =
      _UnwiredPredictionRepository();

  static SubmitPrediction _absentSubmitPrediction() => SubmitPrediction(
    predictionRepository: _unwiredPredictionRepository,
    competitionRepository: _unwiredCompetitionRepository,
    idGenerator: _unwiredIdGenerator,
    clock: _unwiredClock,
  );

  static GetMyPrediction _absentGetMyPrediction() => GetMyPrediction(
    predictionRepository: _unwiredPredictionRepository,
    competitionRepository: _unwiredCompetitionRepository,
  );

  static ListRoundPredictions _absentListRoundPredictions() =>
      ListRoundPredictions(
        predictionRepository: _unwiredPredictionRepository,
        competitionRepository: _unwiredCompetitionRepository,
      );

  /// Throwing scoring repositories backing every "absent" scoring use-case, so
  /// a test that reaches an unwired scoring slice fails loudly instead of
  /// touching a real database.
  static final FixtureResultRepository _unwiredFixtureResultRepository =
      _UnwiredFixtureResultRepository();

  static final ScoreRepository _unwiredScoreRepository =
      _UnwiredScoreRepository();

  static RecordFixtureResult _absentRecordFixtureResult() =>
      RecordFixtureResult(
        resultRepository: _unwiredFixtureResultRepository,
        clock: _unwiredClock,
      );

  static ScoreRound _absentScoreRound() => ScoreRound(
    competitionRepository: _unwiredCompetitionRepository,
    predictionRepository: _unwiredPredictionRepository,
    resultRepository: _unwiredFixtureResultRepository,
    scoreRepository: _unwiredScoreRepository,
  );

  static GetRoundScores _absentGetRoundScores() => GetRoundScores(
    competitionRepository: _unwiredCompetitionRepository,
    scoreRepository: _unwiredScoreRepository,
  );

  /// Throwing ledger repositories backing every "absent" ledger use-case, so a
  /// test that reaches an unwired ledger slice fails loudly instead of touching
  /// a real database.
  static final LedgerRepository _unwiredLedgerRepository =
      _UnwiredLedgerRepository();

  static final ParticipantReader _unwiredParticipantReader =
      _UnwiredParticipantReader();

  static PostRoundToLedger _absentPostRoundToLedger() => PostRoundToLedger(
    competitionRepository: _unwiredCompetitionRepository,
    scoreRepository: _unwiredScoreRepository,
    ledgerRepository: _unwiredLedgerRepository,
    idGenerator: _unwiredIdGenerator,
    clock: _unwiredClock,
  );

  static ReadParticipantLedger _absentReadParticipantLedger() =>
      ReadParticipantLedger(
        participantReader: _unwiredParticipantReader,
        ledgerRepository: _unwiredLedgerRepository,
      );

  /// A single throwing repository backing the "absent" leaderboard use-case, so
  /// a test that reaches an unwired leaderboard slice fails loudly instead of
  /// touching a real database.
  static final LeaderboardRepository _unwiredLeaderboardRepository =
      _UnwiredLeaderboardRepository();

  static GetSeasonLeaderboard _absentGetSeasonLeaderboard() =>
      GetSeasonLeaderboard(
        leaderboardRepository: _unwiredLeaderboardRepository,
        competitionRepository: _unwiredCompetitionRepository,
      );

  /// A single throwing repository backing every "absent" group use-case, so a
  /// test that reaches an unwired group slice fails loudly instead of touching
  /// a real database. The same instance implements BOTH `GroupRepository` AND
  /// `GroupStandingsReader` (the production `PostgresGroupRepository` does too),
  /// so it also backs the absent group-leaderboard read.
  static final _UnwiredGroupRepository _unwiredGroupRepository =
      _UnwiredGroupRepository();

  static final InviteCodeGenerator _unwiredInviteCodeGenerator =
      _UnwiredInviteCodeGenerator();

  static CreateGroup _absentCreateGroup() => CreateGroup(
    repository: _unwiredGroupRepository,
    idGenerator: _unwiredIdGenerator,
    inviteCodeGenerator: _unwiredInviteCodeGenerator,
    clock: _unwiredClock,
  );

  static GetGroup _absentGetGroup() =>
      GetGroup(repository: _unwiredGroupRepository);

  static JoinGroupByInvite _absentJoinGroupByInvite() => JoinGroupByInvite(
    repository: _unwiredGroupRepository,
    idGenerator: _unwiredIdGenerator,
    clock: _unwiredClock,
  );

  static RenameGroup _absentRenameGroup() =>
      RenameGroup(repository: _unwiredGroupRepository);

  static RegenerateInvite _absentRegenerateInvite() => RegenerateInvite(
    repository: _unwiredGroupRepository,
    inviteCodeGenerator: _unwiredInviteCodeGenerator,
  );

  static ListGroupMembers _absentListGroupMembers() =>
      ListGroupMembers(repository: _unwiredGroupRepository);

  static GetGroupLeaderboard _absentGetGroupLeaderboard() =>
      GetGroupLeaderboard(
        repository: _unwiredGroupRepository,
        standingsReader: _unwiredGroupRepository,
      );

  /// A single throwing reaction repository backing every "absent" Social
  /// reaction use-case, and a throwing feed reader backing the "absent" feed
  /// read, so a test that reaches an unwired social slice fails loudly instead
  /// of touching a real database. The group gate reuses the same
  /// `_unwiredGroupRepository` as the Groups slice.
  static final ReactionRepository _unwiredReactionRepository =
      _UnwiredReactionRepository();

  static final ActivityFeedReader _unwiredActivityFeedReader =
      _UnwiredActivityFeedReader();

  static ReactToRound _absentReactToRound() => ReactToRound(
    reactions: _unwiredReactionRepository,
    groups: _unwiredGroupRepository,
    idGenerator: _unwiredIdGenerator,
    clock: _unwiredClock,
  );

  static RemoveReaction _absentRemoveReaction() => RemoveReaction(
    reactions: _unwiredReactionRepository,
    groups: _unwiredGroupRepository,
  );

  static ListRoundReactions _absentListRoundReactions() => ListRoundReactions(
    reactions: _unwiredReactionRepository,
    groups: _unwiredGroupRepository,
  );

  static GetGroupActivityFeed _absentGetGroupActivityFeed() =>
      GetGroupActivityFeed(
        feed: _unwiredActivityFeedReader,
        groups: _unwiredGroupRepository,
      );

  /// A single throwing notification repository backing every "absent"
  /// Notifications use-case, so a test that reaches an unwired notification
  /// slice fails loudly instead of touching a real database. The three
  /// recipient-facing use-cases (`ListMyNotifications`/`GetUnreadCount`/
  /// `MarkNotificationRead`) are the only client-callable notification surface
  /// (decision #4 — creation is server-triggered only, no client route).
  static final NotificationRepository _unwiredNotificationRepository =
      _UnwiredNotificationRepository();

  static ListMyNotifications _absentListMyNotifications() =>
      ListMyNotifications(notifications: _unwiredNotificationRepository);

  static GetUnreadCount _absentGetUnreadCount() =>
      GetUnreadCount(notifications: _unwiredNotificationRepository);

  static MarkNotificationRead _absentMarkNotificationRead() =>
      MarkNotificationRead(
        notifications: _unwiredNotificationRepository,
        clock: _unwiredClock,
      );

  /// Throwing admin repositories backing every "absent" Admin Panel use-case,
  /// so a test that reaches an unwired admin slice fails loudly instead of
  /// touching a real database. The user-sanction path (`SuspendUser`/
  /// `ReinstateUser`) and the support-read path (`ViewParticipantLedger`) both
  /// record to the audit trail, so their stand-ins share one throwing
  /// `AuditRecorder` over a throwing `_UnwiredAuditLogRepository`; the support
  /// read reuses the same throwing participant reader + ledger repository as the
  /// Ledger slice.
  static final UserAdminRepository _unwiredUserAdminRepository =
      _UnwiredUserAdminRepository();

  static final AuditLogRepository _unwiredAuditLogRepository =
      _UnwiredAuditLogRepository();

  static AuditRecorder _absentAuditRecorder() => AuditRecorder(
    auditLog: _unwiredAuditLogRepository,
    idGenerator: _unwiredIdGenerator,
    clock: _unwiredClock,
  );

  static SuspendUser _absentSuspendUser() => SuspendUser(
    users: _unwiredUserAdminRepository,
    auditRecorder: _absentAuditRecorder(),
  );

  static ReinstateUser _absentReinstateUser() => ReinstateUser(
    users: _unwiredUserAdminRepository,
    auditRecorder: _absentAuditRecorder(),
  );

  static ListAuditLog _absentListAuditLog() =>
      ListAuditLog(auditLog: _unwiredAuditLogRepository);

  static ViewParticipantLedger _absentViewParticipantLedger() =>
      ViewParticipantLedger(
        participantReader: _unwiredParticipantReader,
        ledgerRepository: _unwiredLedgerRepository,
        auditRecorder: _absentAuditRecorder(),
      );

  /// The Postgres connection owned by a production root. Null for roots built
  /// via [CompositionRoot.forTesting], which own no infrastructure.
  final PostgresConnection? _connection;

  /// The JWKS client owned by a production root, closed on [dispose]. Null for
  /// test roots.
  final JwksClient? _jwksClient;

  /// The health use-case, ready to be invoked by routes.
  final CheckHealth checkHealth;

  /// Establishes the request principal from an `Authorization` header.
  final AuthenticateRequest authenticateRequest;

  /// Resolves the canonical [User] for a verified principal (backs `/me`).
  final GetCurrentUser getCurrentUser;

  /// Creates a competition (admin-only command).
  final CreateCompetition createCompetition;

  /// Starts a season under a competition (admin-only command).
  final StartSeason startSeason;

  /// Opens a round in a season, freezing the ruleset (admin-only command).
  final OpenRound openRound;

  /// Locks an open round (admin-only command).
  final LockRound lockRound;

  /// Links a fixture to an open round (admin-only command).
  final LinkFixtureToRound linkFixtureToRound;

  /// Enrols the calling user into a season (any authenticated user).
  final JoinCompetition joinCompetition;

  /// Reads a single competition by id (any authenticated user; the browse
  /// detail read — BLOCKER FA-1). Read-only, no side effect.
  final GetCompetition getCompetition;

  /// Reads a single round by id (any authenticated user; renders a round's
  /// status/deadline before the prediction form — BLOCKER FA-1).
  final GetRound getRound;

  /// Lists the browsable public competition catalogue (any authenticated user;
  /// the discovery read — BLOCKER FA-1). Never a points/write path.
  final ListCompetitions listCompetitions;

  /// Lists a competition's seasons ordered by label (any authenticated user;
  /// the browse navigation step competition → season — BLOCKER FA-1 / DEFECT
  /// AD-2). The domain has no "current/active season" concept, so a multi-season
  /// competition must be browsed season-by-season. Read-only, no side effect.
  final ListCompetitionSeasons listCompetitionSeasons;

  /// Lists a season's rounds in sequence order (any authenticated user; the
  /// browse navigation step competition → season → round — BLOCKER FA-1).
  final ListSeasonRounds listSeasonRounds;

  /// Lists a round's fixtures in matchday order (any authenticated user; the
  /// set a client renders to build the prediction form — BLOCKER FA-1). This is
  /// the Competition-context browse read, distinct from the Prediction phase's
  /// internal `PredictionRepository.listRoundFixtures`.
  final ListRoundFixtures listRoundFixtures;

  /// Submits (or idempotently amends) the caller's prediction for a round.
  final SubmitPrediction submitPrediction;

  /// Reads the caller's own prediction for a round (any status; self-read).
  final GetMyPrediction getMyPrediction;

  /// Lists every participant's prediction for a locked round (visibility-gated).
  final ListRoundPredictions listRoundPredictions;

  /// Records the actual result of a fixture (admin-only ingestion; the Axiom-3
  /// football seam).
  final RecordFixtureResult recordFixtureResult;

  /// Scores every prediction in a locked round (admin-only command; the points
  /// are computed and written server-side — Axioms 2/5).
  final ScoreRound scoreRound;

  /// Reads every participant's score for a scored round (visibility-gated).
  final GetRoundScores getRoundScores;

  /// Posts a scored round to the append-only Ledger (admin-only command; the
  /// point amounts are copied server-side from the frozen scores — Axioms 2/5;
  /// idempotent on the natural dedupe key — Axiom 4).
  final PostRoundToLedger postRoundToLedger;

  /// Reads a participant's projected balance / append-only entry stream
  /// (self-read only — a caller sees only a participant they own).
  final ReadParticipantLedger readParticipantLedger;

  /// Reads a season's ranked standings — its leaderboard (a read-side projection
  /// over the append-only ledger; season-membership gated, never a points
  /// write — Axioms 1/5).
  final GetSeasonLeaderboard getSeasonLeaderboard;

  /// Creates a new private group (any authenticated user; the creator becomes
  /// the sole owner, owner membership written atomically — Groups decision #2).
  final CreateGroup createGroup;

  /// Reads a single group + its member count (member-only visibility gate, no
  /// existence oracle — Groups decision #3).
  final GetGroup getGroup;

  /// Joins a group via its shareable invite code (any authenticated user;
  /// zero-friction instant join, idempotent — Groups decision #2/#3).
  final JoinGroupByInvite joinGroupByInvite;

  /// Renames a group (owner-only, per-group `GroupRole` gate in the use-case —
  /// Groups decision #2).
  final RenameGroup renameGroup;

  /// Regenerates a group's invite code, revoking the previously-shared link
  /// (owner-only — Groups decision #2/#3).
  final RegenerateInvite regenerateInvite;

  /// Lists a group's members (member-only visibility gate, no existence oracle —
  /// Groups decision #3).
  final ListGroupMembers listGroupMembers;

  /// Reads a group's ranked standings for a season — the season leaderboard
  /// projection filtered to the group's membership (member-only; NO new points
  /// source, NO new ranking logic — Groups decision #4, Axiom 5).
  final GetGroupLeaderboard getGroupLeaderboard;

  /// Records (or idempotently changes) a member's emoji reaction to a
  /// round-result within a group (any authenticated user, member-gated;
  /// Tier-3 — a failure never blocks a Tier-1 core operation — Social
  /// decisions #1/#2/#4).
  final ReactToRound reactToRound;

  /// Removes the caller's own reaction to a round-result within a group
  /// (member-gated, idempotent — Social decision #2).
  final RemoveReaction removeReaction;

  /// Lists a round-result's reactions within a group (member-gated read —
  /// Social decision #3).
  final ListRoundReactions listRoundReactions;

  /// Reads a group's activity feed — a pure read projection over already-
  /// ratified data (member-gated; NO table, NEVER a source of truth — Social
  /// decision #2).
  final GetGroupActivityFeed getGroupActivityFeed;

  /// Lists the caller's OWN notifications, newest-first (recipient-only —
  /// Notifications decision #4; no membership check). The recipient is bound
  /// from the verified token, never a body/path.
  final ListMyNotifications listMyNotifications;

  /// Reads the caller's OWN unread-notification count (recipient-only badge
  /// count — Notifications decision #4).
  final GetUnreadCount getUnreadCount;

  /// Marks the caller's OWN notification read (recipient-only, idempotent; a
  /// foreign/unknown id is refused identically as `notification.not_found` with
  /// no existence oracle — Notifications decision #4). The one client-safe
  /// Tier-3 mutation.
  final MarkNotificationRead markNotificationRead;

  /// Suspends a user — the reversible admin sanction (admin-only, gated inside
  /// the use-case; a mandatory reason feeds the immutable audit record — Admin
  /// Panel decisions OPEN-A #1 / OPEN-B). The genuinely-new domain capability of
  /// the phase.
  final SuspendUser suspendUser;

  /// Reinstates a suspended user — the mirror of [suspendUser] (admin-only,
  /// mandatory reason, audited — decision OPEN-A #1).
  final ReinstateUser reinstateUser;

  /// Reads the append-only admin audit trail, newest-first (admin-only — the
  /// trail is itself a privileged surface; decision OPEN-B).
  final ListAuditLog listAuditLog;

  /// The narrow cross-user read-for-support: an admin reads a SINGLE
  /// participant's ledger by explicit id, the read itself audited (admin-only;
  /// never a bulk/export view — decision OPEN-A #3).
  final ViewParticipantLedger viewParticipantLedger;

  /// Builds the graph from process environment, failing fast on misconfig.
  static Future<CompositionRoot> bootstrap(Map<String, String> env) async {
    final config = _require(PostgresConfig.fromEnv(env), 'Postgres config');
    final authConfig = _require(
      AuthConfig.fromEnv(env),
      'Supabase auth config',
    );

    final connectionResult = await PostgresConnection.open(config);
    final connection = switch (connectionResult) {
      Ok<PostgresConnection>(:final value) => value,
      Err<PostgresConnection>(:final error) => throw StateError(
        'Cannot start: $error',
      ),
    };

    // Health slice.
    final checkHealth = CheckHealth(PostgresHealthRepository(connection));

    // Identity slice: JWKS-backed ES256 verifier (+ HS256 legacy fallback) and
    // the Postgres-backed canonical user directory.
    final jwksClient = JwksClient(authConfig.jwksUri);
    final verifier = SupabaseJwtVerifier(authConfig, jwksClient);
    final directory = PostgresUserDirectory(connection);

    // Competition slice: the Postgres-backed repository, the configured
    // ruleset provider (the placeholder-free Scoring seam), and the shared
    // id/clock adapters. Every competition use-case is wired here so nothing
    // else in the server constructs infrastructure.
    final competitionRepository = PostgresCompetitionRepository(connection);
    const rulesetProvider = ConfiguredRulesetProvider();
    final idGenerator = UuidIdGenerator();
    const clock = SystemClock();

    // Prediction slice: the platform's highest-volume integrity-critical write
    // path, kept on its own Postgres-backed repository (aggregate separate from
    // Competition, Database ADR §2.1). Each use-case also reads the Competition
    // repository (round/participant resolution) without contending on its
    // writes. Points are never wired here — Scoring is a later phase.
    final predictionRepository = PostgresPredictionRepository(connection);

    // Scoring slice: its own Postgres-backed adapters over the scoring.* tables
    // (the actual-result seam — Axiom 3 option (a) — and the server-computed
    // round scores). ScoreRound reuses the competition + prediction repos
    // (round/ruleset/participant resolution + the one prediction per round) and
    // the pure domain scoring service; points are written server-side only
    // (Axioms 2/5). GetRoundScores gates the read to a scored round.
    final fixtureResultRepository = PostgresFixtureResultRepository(connection);
    final scoreRepository = PostgresScoreRepository(connection);

    // Ledger slice: its own Postgres-backed adapters over the ledger.* tables
    // (the append-only PointEntry stream). PostRoundToLedger reads the scored
    // round (competition repo, gated on RoundStatus.scored) + its already-
    // persisted scores (score repo) and appends one round_score credit per
    // participant, idempotently on the ratified dedupe key (Axioms 2/4/5).
    // ReadParticipantLedger resolves a participant by id (the narrow
    // ParticipantReader port, over competition.participants) to gate the read
    // to a self-owned participant, then projects the balance / lists the stream.
    final ledgerRepository = PostgresLedgerRepository(connection);
    final participantReader = PostgresParticipantReader(connection);

    // Leaderboards slice: a read-only Postgres-backed adapter over the
    // season-scoped projection VIEW leaderboard.season_standings (a SUM(amount)
    // over the append-only ledger — never a second points source, Axiom 5).
    // GetSeasonLeaderboard reads the unranked projection + gates the read to a
    // member of the season (competition repo) and ranks it in the pure domain.
    final leaderboardRepository = PostgresLeaderboardRepository(connection);

    // Groups slice: a single Postgres-backed adapter over the group.* tables
    // (`PostgresGroupRepository` implements BOTH `GroupRepository` AND
    // `GroupStandingsReader`, so the same instance backs the group commands and
    // the group-leaderboard read). Groups are an orthogonal social container
    // (decision #1: NO competition/round/prediction/leaderboard object gains a
    // group ref). The invite code is server-generated via a crypto-strong
    // adapter (`UuidInviteCodeGenerator`, `dart:math` `Random.secure` — §3: no
    // new dependency). The group leaderboard reuses the ratified
    // `leaderboard.season_standings` VIEW intersected with group membership
    // (decision #4 — no new points source), ranked by the pure domain in the
    // use-case. Owner-authority (rename/regenerate) is a per-group `GroupRole`
    // gate inside the use-case, never the platform role.
    final groupRepository = PostgresGroupRepository(connection);
    final inviteCodeGenerator = UuidInviteCodeGenerator();

    // Social slice (Tier-3, peripheral, rebuildable — NEVER a source of truth;
    // Database ADR §3 / Deployment ADR §Tier-3). One Postgres-backed adapter
    // over the single new stored surface `social.reactions`
    // (`PostgresReactionRepository`) plus a pure read-projection reader for the
    // Activity Feed (`PostgresActivityFeedReader` — NO table, decision #2). All
    // social use-cases reuse the ratified group member gate
    // (`group.not_a_member`, no existence oracle — decision #3) via the same
    // `groupRepository` the Groups slice uses; the author is bound from the
    // verified token inside each use-case, never a body (Security ADR §2).
    // Social carries NO points (Axiom 5) and NO open-graph edge (ADR-001); a
    // Social failure is confined to its endpoint and never blocks a Tier-1
    // core operation (decision #4).
    final reactionRepository = PostgresReactionRepository(connection);
    final activityFeedReader = PostgresActivityFeedReader(connection);

    // Notifications slice (Tier-3, peripheral, rebuildable — NEVER a source of
    // truth; Database ADR §3 / Deployment ADR §Tier-3). One Postgres-backed
    // adapter over the single new stored surface `notification.notifications`
    // (`PostgresNotificationRepository`). Only the three RECIPIENT-facing
    // use-cases are wired to a client route (decision #4: the read/mark surface
    // is recipient-only — a notification's recipient must equal the verified
    // principal; there is NO group/season membership check and NO client route
    // that creates a notification). Each recipient use-case binds the recipient
    // from the verified token, never a body (Security ADR §2); a foreign/unknown
    // id is refused identically as `notification.not_found` (no existence
    // oracle — mirror of the Ledger self-read). Notifications carries NO points
    // (Axiom 5) and NO open-graph edge (ADR-001); a failure is confined to its
    // endpoint and never blocks a Tier-1 core operation (decision #4).
    //
    // NOTE (composition gap — recorded in §4, not silently ignored): the three
    // server-side creation commands (`CreateNotification` + `NotifyRoundScored`/
    // `NotifyGroupMemberJoined`/`NotifyReactionReceived`) are complete and
    // exported by the application layer, but are NOT client-callable and so are
    // deliberately NOT wired here — they must be invoked as best-effort Tier-3
    // effects at the ScoreRound/JoinGroup/ReactToRound composition edges. That
    // trigger-edge wiring is a separate, explicit step tracked in §4; this
    // bootstrap wires only the recipient-facing read/mark surface that has an
    // HTTP route.
    final notificationRepository = PostgresNotificationRepository(connection);

    // Admin slice (phase 11). The ONE new stored surface is the append-only
    // `admin.audit_log` (migration 0010); the user sanction toggles the
    // EXISTING `identity.users.status` (no new user table — decision §2 #1,
    // reuse over duplication). A single audit-write path (`AuditRecorder`,
    // reusing the shared `idGenerator`/`clock`) is shared by every audited
    // admin use-case, so the trail is written one way (Security ADR §2.4). The
    // support read (`ViewParticipantLedger`) reuses the same `participantReader`
    // + `ledgerRepository` already built for the Ledger slice above (decision
    // §2 #1); it is a DIFFERENT gate from `ReadParticipantLedger` (admin cross-
    // user read, itself audited — decision OPEN-A #3), never a duplicate.
    final userAdminRepository = PostgresUserAdminRepository(connection);
    final auditLogRepository = PostgresAuditLogRepository(connection);
    final auditRecorder = AuditRecorder(
      auditLog: auditLogRepository,
      idGenerator: idGenerator,
      clock: clock,
    );

    return CompositionRoot._(
      connection: connection,
      jwksClient: jwksClient,
      checkHealth: checkHealth,
      authenticateRequest: AuthenticateRequest(verifier),
      getCurrentUser: GetCurrentUser(directory),
      createCompetition: CreateCompetition(
        repository: competitionRepository,
        idGenerator: idGenerator,
      ),
      startSeason: StartSeason(
        repository: competitionRepository,
        idGenerator: idGenerator,
      ),
      openRound: OpenRound(
        repository: competitionRepository,
        rulesetProvider: rulesetProvider,
        idGenerator: idGenerator,
      ),
      lockRound: LockRound(competitionRepository),
      linkFixtureToRound: LinkFixtureToRound(competitionRepository),
      joinCompetition: JoinCompetition(
        repository: competitionRepository,
        idGenerator: idGenerator,
        clock: clock,
      ),
      // Read-only Competition-browse query use-cases (BLOCKER FA-1): every one
      // reuses the same `competitionRepository` as the write commands (its new
      // list reads are strictly additive — DEFECT FA-2 closed). No side effect,
      // no points, no new infrastructure.
      getCompetition: GetCompetition(repository: competitionRepository),
      getRound: GetRound(repository: competitionRepository),
      listCompetitions: ListCompetitions(repository: competitionRepository),
      listCompetitionSeasons: ListCompetitionSeasons(
        repository: competitionRepository,
      ),
      listSeasonRounds: ListSeasonRounds(repository: competitionRepository),
      listRoundFixtures: ListRoundFixtures(repository: competitionRepository),
      submitPrediction: SubmitPrediction(
        predictionRepository: predictionRepository,
        competitionRepository: competitionRepository,
        idGenerator: idGenerator,
        clock: clock,
      ),
      getMyPrediction: GetMyPrediction(
        predictionRepository: predictionRepository,
        competitionRepository: competitionRepository,
      ),
      listRoundPredictions: ListRoundPredictions(
        predictionRepository: predictionRepository,
        competitionRepository: competitionRepository,
      ),
      recordFixtureResult: RecordFixtureResult(
        resultRepository: fixtureResultRepository,
        clock: clock,
      ),
      scoreRound: ScoreRound(
        competitionRepository: competitionRepository,
        predictionRepository: predictionRepository,
        resultRepository: fixtureResultRepository,
        scoreRepository: scoreRepository,
      ),
      getRoundScores: GetRoundScores(
        competitionRepository: competitionRepository,
        scoreRepository: scoreRepository,
      ),
      postRoundToLedger: PostRoundToLedger(
        competitionRepository: competitionRepository,
        scoreRepository: scoreRepository,
        ledgerRepository: ledgerRepository,
        idGenerator: idGenerator,
        clock: clock,
      ),
      readParticipantLedger: ReadParticipantLedger(
        participantReader: participantReader,
        ledgerRepository: ledgerRepository,
      ),
      getSeasonLeaderboard: GetSeasonLeaderboard(
        leaderboardRepository: leaderboardRepository,
        competitionRepository: competitionRepository,
      ),
      createGroup: CreateGroup(
        repository: groupRepository,
        idGenerator: idGenerator,
        inviteCodeGenerator: inviteCodeGenerator,
        clock: clock,
      ),
      getGroup: GetGroup(repository: groupRepository),
      joinGroupByInvite: JoinGroupByInvite(
        repository: groupRepository,
        idGenerator: idGenerator,
        clock: clock,
      ),
      renameGroup: RenameGroup(repository: groupRepository),
      regenerateInvite: RegenerateInvite(
        repository: groupRepository,
        inviteCodeGenerator: inviteCodeGenerator,
      ),
      listGroupMembers: ListGroupMembers(repository: groupRepository),
      getGroupLeaderboard: GetGroupLeaderboard(
        repository: groupRepository,
        standingsReader: groupRepository,
      ),
      reactToRound: ReactToRound(
        reactions: reactionRepository,
        groups: groupRepository,
        idGenerator: idGenerator,
        clock: clock,
      ),
      removeReaction: RemoveReaction(
        reactions: reactionRepository,
        groups: groupRepository,
      ),
      listRoundReactions: ListRoundReactions(
        reactions: reactionRepository,
        groups: groupRepository,
      ),
      getGroupActivityFeed: GetGroupActivityFeed(
        feed: activityFeedReader,
        groups: groupRepository,
      ),
      listMyNotifications: ListMyNotifications(
        notifications: notificationRepository,
      ),
      getUnreadCount: GetUnreadCount(notifications: notificationRepository),
      markNotificationRead: MarkNotificationRead(
        notifications: notificationRepository,
        clock: clock,
      ),
      suspendUser: SuspendUser(
        users: userAdminRepository,
        auditRecorder: auditRecorder,
      ),
      reinstateUser: ReinstateUser(
        users: userAdminRepository,
        auditRecorder: auditRecorder,
      ),
      listAuditLog: ListAuditLog(auditLog: auditLogRepository),
      viewParticipantLedger: ViewParticipantLedger(
        participantReader: participantReader, // already built (Ledger slice)
        ledgerRepository: ledgerRepository, // already built (Ledger slice)
        auditRecorder: auditRecorder,
      ),
    );
  }

  /// Unwraps a config [Result], throwing a fatal [StateError] on failure so the
  /// process refuses to start with invalid configuration (fail-fast).
  static T _require<T>(Result<T> result, String what) => switch (result) {
    Ok<T>(:final value) => value,
    Err<T>(:final error) => throw StateError('Invalid $what: $error'),
  };

  /// Graceful shutdown hook. A no-op for test roots, which own no resources.
  Future<void> dispose() async {
    _jwksClient?.close();
    await _connection?.close();
  }

  /// Cached bootstrap future for the running process.
  ///
  /// We cache the *Future*, not the resolved instance, so that concurrent
  /// callers awaiting [instance] before the first bootstrap completes all
  /// share the single in-flight bootstrap rather than triggering a race that
  /// opens multiple connection pools.
  static Future<CompositionRoot>? _instanceFuture;

  /// Returns the process-wide root, building it once on first access.
  static Future<CompositionRoot> instance() {
    return _instanceFuture ??= bootstrap(Platform.environment);
  }

  /// Resets the cached root. Intended for tests and controlled shutdown; not
  /// used on the request hot path.
  static Future<void> reset() async {
    final existing = _instanceFuture;
    _instanceFuture = null;
    if (existing != null) {
      final root = await existing;
      await root.dispose();
    }
  }
}

/// Backs an "absent" [CheckHealth] in [CompositionRoot.forTesting]: throws if a
/// test reaches a health slice it never wired.
final class _UnwiredHealthRepository implements HealthRepository {
  @override
  Future<Result<bool>> pingDatabase() =>
      throw StateError('CheckHealth was not wired into this test root');
}

/// Backs an "absent" [AuthenticateRequest]: throws if a test reaches the auth
/// slice it never wired.
final class _UnwiredTokenVerifier implements TokenVerifier {
  @override
  Future<Result<AuthenticatedUser>> verify(String bearerToken) =>
      throw StateError('AuthenticateRequest was not wired into this test root');
}

/// Backs an "absent" [GetCurrentUser]: throws if a test reaches the directory
/// slice it never wired.
final class _UnwiredUserDirectory implements UserDirectory {
  @override
  Future<Result<User>> ensureUser(AuthenticatedUser principal) =>
      throw StateError('GetCurrentUser was not wired into this test root');
}

/// Backs every "absent" competition use-case: any method throws so a test that
/// reaches an unwired competition slice fails loudly instead of touching a
/// real database.
final class _UnwiredCompetitionRepository implements CompetitionRepository {
  static Never _unwired() =>
      throw StateError('A competition use-case was not wired into this root');

  @override
  Future<Result<void>> saveCompetition(Competition competition) => _unwired();

  @override
  Future<Result<Competition>> findCompetition(CompetitionId id) => _unwired();

  @override
  Future<Result<void>> saveSeason(CompetitionSeason season) => _unwired();

  @override
  Future<Result<CompetitionSeason>> findSeason(SeasonId id) => _unwired();

  @override
  Future<Result<void>> saveRound(Round round) => _unwired();

  @override
  Future<Result<Round>> findRound(RoundId id) => _unwired();

  @override
  Future<Result<void>> updateRoundStatus(
    Round round,
    RoundStatus expectedPriorStatus,
  ) => _unwired();

  @override
  Future<Result<void>> saveRoundFixture(RoundFixture link) => _unwired();

  @override
  Future<Result<void>> saveParticipant(Participant participant) => _unwired();

  @override
  Future<Result<Participant?>> findParticipant(
    SeasonId seasonId,
    UserId userId,
  ) => _unwired();

  @override
  Future<Result<List<Competition>>> listCompetitions() => _unwired();

  @override
  Future<Result<List<CompetitionSeason>>> listCompetitionSeasons(
    CompetitionId competitionId,
  ) => _unwired();

  @override
  Future<Result<List<Round>>> listSeasonRounds(SeasonId seasonId) => _unwired();

  @override
  Future<Result<List<RoundFixture>>> listRoundFixtures(RoundId roundId) =>
      _unwired();
}

/// Backs an "absent" [OpenRound]'s ruleset provider.
final class _UnwiredRulesetProvider implements RulesetProvider {
  @override
  Future<Result<RulesetSnapshot>> currentSnapshotFor(FormatType format) =>
      throw StateError('OpenRound was not wired into this root');
}

/// Backs "absent" competition use-cases' id generator.
final class _UnwiredIdGenerator implements IdGenerator {
  @override
  String newUuid() =>
      throw StateError('A competition use-case was not wired into this root');
}

/// Backs "absent" competition use-cases' clock.
final class _UnwiredClock implements Clock {
  @override
  DateTime nowUtc() =>
      throw StateError('JoinCompetition was not wired into this root');
}

/// Backs every "absent" prediction use-case: any method throws so a test that
/// reaches an unwired prediction slice fails loudly instead of touching a real
/// database.
final class _UnwiredPredictionRepository implements PredictionRepository {
  static Never _unwired() =>
      throw StateError('A prediction use-case was not wired into this root');

  @override
  Future<Result<PredictionView?>> findByRoundAndParticipant(
    RoundId roundId,
    ParticipantId participantId,
  ) => _unwired();

  @override
  Future<Result<void>> save(Prediction prediction, DateTime submittedAt) =>
      _unwired();

  @override
  Future<Result<void>> update(Prediction prediction, DateTime submittedAt) =>
      _unwired();

  @override
  Future<Result<List<PredictionView>>> listByRound(RoundId roundId) =>
      _unwired();

  @override
  Future<Result<List<RoundFixture>>> listRoundFixtures(RoundId roundId) =>
      _unwired();
}

/// Backs every "absent" scoring use-case's fixture-result port: any method
/// throws so a test that reaches an unwired scoring slice fails loudly instead
/// of touching a real database.
final class _UnwiredFixtureResultRepository implements FixtureResultRepository {
  static Never _unwired() =>
      throw StateError('A scoring use-case was not wired into this root');

  @override
  Future<Result<void>> upsert(FixtureResult result, DateTime recordedAt) =>
      _unwired();

  @override
  Future<Result<FixtureResult?>> findByFixture(FixtureRef fixture) =>
      _unwired();

  @override
  Future<Result<List<FixtureResult>>> findByFixtures(
    List<FixtureRef> fixtures,
  ) => _unwired();
}

/// Backs every "absent" scoring use-case's score port: any method throws so a
/// test that reaches an unwired scoring slice fails loudly.
final class _UnwiredScoreRepository implements ScoreRepository {
  static Never _unwired() =>
      throw StateError('A scoring use-case was not wired into this root');

  @override
  Future<Result<void>> saveRoundScores(List<RoundScore> scores) => _unwired();

  @override
  Future<Result<List<RoundScore>>> listByRound(RoundId roundId) => _unwired();
}

/// Backs every "absent" ledger use-case's ledger port: any method throws so a
/// test that reaches an unwired ledger slice fails loudly instead of touching a
/// real database.
final class _UnwiredLedgerRepository implements LedgerRepository {
  static Never _unwired() =>
      throw StateError('A ledger use-case was not wired into this root');

  @override
  Future<Result<List<PointEntry>>> appendEntries(List<PointEntry> entries) =>
      _unwired();

  @override
  Future<Result<List<PointEntry>>> listEntries(ParticipantId participantId) =>
      _unwired();

  @override
  Future<Result<LedgerBalance>> balanceFor(ParticipantId participantId) =>
      _unwired();
}

/// Backs every "absent" Admin Panel user-sanction use-case
/// (`SuspendUser`/`ReinstateUser`): any method throws so a test that reaches an
/// unwired admin slice fails loudly instead of touching a real database.
final class _UnwiredUserAdminRepository implements UserAdminRepository {
  static Never _unwired() =>
      throw StateError('An admin use-case was not wired into this root');

  @override
  Future<Result<User?>> findUserById(UserId id) => _unwired();

  @override
  Future<Result<User>> updateUser(User user) => _unwired();
}

/// Backs the "absent" audit trail behind every unwired admin use-case: any
/// method throws so a test that reaches an unwired audit path fails loudly
/// instead of silently dropping an audit record.
final class _UnwiredAuditLogRepository implements AuditLogRepository {
  static Never _unwired() =>
      throw StateError('An admin use-case was not wired into this root');

  @override
  Future<Result<AuditEntry>> append(AuditEntry entry) => _unwired();

  @override
  Future<Result<List<AuditEntry>>> list({required int limit}) => _unwired();
}

/// Backs an "absent" [ReadParticipantLedger]'s participant reader: throws so a
/// test that reaches an unwired ledger read slice fails loudly.
final class _UnwiredParticipantReader implements ParticipantReader {
  @override
  Future<Result<Participant?>> findParticipantById(ParticipantId id) =>
      throw StateError('A ledger use-case was not wired into this root');
}

/// Backs the "absent" [GetSeasonLeaderboard]'s repository: throws so a test that
/// reaches an unwired leaderboard slice fails loudly instead of touching a real
/// database.
final class _UnwiredLeaderboardRepository implements LeaderboardRepository {
  @override
  Future<Result<List<LeaderboardEntry>>> seasonStandings(SeasonId seasonId) =>
      throw StateError('The leaderboard use-case was not wired into this root');
}

/// Backs every "absent" group use-case: any method throws so a test that
/// reaches an unwired group slice fails loudly instead of touching a real
/// database. Implements BOTH `GroupRepository` AND `GroupStandingsReader`
/// (mirroring the production `PostgresGroupRepository`), so a single instance
/// backs the group commands and the group-leaderboard read alike.
final class _UnwiredGroupRepository
    implements GroupRepository, GroupStandingsReader {
  static Never _unwired() =>
      throw StateError('A group use-case was not wired into this root');

  @override
  Future<Result<void>> createGroupWithOwner(
    Group group,
    GroupMembership ownerMembership,
  ) => _unwired();

  @override
  Future<Result<Group?>> findGroup(GroupId id) => _unwired();

  @override
  Future<Result<Group?>> findByInviteCode(InviteCode inviteCode) => _unwired();

  @override
  Future<Result<void>> updateGroup(Group group) => _unwired();

  @override
  Future<Result<void>> saveMembership(GroupMembership membership) => _unwired();

  @override
  Future<Result<GroupMembership?>> findMembership(
    GroupId groupId,
    UserId userId,
  ) => _unwired();

  @override
  Future<Result<List<GroupMembership>>> listMemberships(GroupId groupId) =>
      _unwired();

  @override
  Future<Result<List<GroupStandingEntry>>> groupSeasonStandings({
    required GroupId groupId,
    required SeasonId seasonId,
  }) => _unwired();
}

/// Backs an "absent" group create/regenerate use-case's invite-code generator:
/// throws if a test reaches a group slice it never wired.
final class _UnwiredInviteCodeGenerator implements InviteCodeGenerator {
  @override
  InviteCode newCode() =>
      throw StateError('A group use-case was not wired into this root');
}

/// Backs every "absent" Social reaction use-case: any method throws so a test
/// that reaches an unwired social slice fails loudly instead of touching a real
/// database.
final class _UnwiredReactionRepository implements ReactionRepository {
  static Never _unwired() =>
      throw StateError('A social use-case was not wired into this root');

  @override
  Future<Result<void>> upsertReaction(Reaction reaction) => _unwired();

  @override
  Future<Result<Reaction?>> findReaction(
    GroupId groupId,
    RoundId roundId,
    UserId userId,
  ) => _unwired();

  @override
  Future<Result<List<Reaction>>> listReactionsForRound(
    GroupId groupId,
    RoundId roundId,
  ) => _unwired();

  @override
  Future<Result<bool>> removeReaction(
    GroupId groupId,
    RoundId roundId,
    UserId userId,
  ) => _unwired();
}

/// Backs an "absent" [GetGroupActivityFeed]'s feed reader: throws if a test
/// reaches the social feed slice it never wired.
final class _UnwiredActivityFeedReader implements ActivityFeedReader {
  @override
  Future<Result<List<ActivityEvent>>> groupActivityFeed({
    required GroupId groupId,
    required int limit,
  }) => throw StateError('A social use-case was not wired into this root');
}

/// Backs every "absent" Notifications use-case: any method throws so a test
/// that reaches an unwired notification slice fails loudly instead of touching
/// a real database.
final class _UnwiredNotificationRepository implements NotificationRepository {
  static Never _unwired() =>
      throw StateError('A notification use-case was not wired into this root');

  @override
  Future<Result<bool>> createIfAbsent(Notification notification) => _unwired();

  @override
  Future<Result<List<Notification>>> listForRecipient(
    UserId recipientId, {
    required int limit,
  }) => _unwired();

  @override
  Future<Result<Notification?>> findForRecipient(
    NotificationId id,
    UserId recipientId,
  ) => _unwired();

  @override
  Future<Result<bool?>> markRead(
    NotificationId id,
    UserId recipientId,
    DateTime readAt,
  ) => _unwired();

  @override
  Future<Result<int>> unreadCount(UserId recipientId) => _unwired();
}
