import 'dart:convert';

import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:infrastructure/src/db/postgres_connection.dart';
// `postgres` exports its own `Result`; we only need its exception hierarchy
// here (to read the SQLSTATE `code` / `constraintName` off a `ServerException`),
// so hide `Result` to keep `Result<T>` unambiguously our `shared` union.
import 'package:postgres/postgres.dart' hide Result;
import 'package:shared/shared.dart';

/// Postgres-backed [CompetitionRepository] over the `competition.*` tables
/// (Database ADR §3; migration `0002_competition.sql`).
///
/// The adapter is *total* (Application ADR §2): it never throws — every outcome
/// is a typed [Result]. It speaks only in domain aggregates and typed ids; SQL
/// and rows never leak past this boundary, so the use-cases stay pure and
/// testable against an in-memory fake.
///
/// Error mapping (the port's general contract):
/// * A storage-only integrity conflict the application could not pre-empt — a
///   unique violation (`23505`), a foreign-key violation (`23503`), or a
///   check/trigger rejection (`23514`, e.g. the ruleset-freeze or lifecycle
///   backstop) — is surfaced as [ErrorKind.invariant] with the *domain* code the
///   use-case expects (e.g. `competition.already_joined`), decided by the
///   violated constraint. This is the "database is the last line of defence"
///   axiom made visible: the DB catches what slipped past the app, and the
///   adapter translates it back into a business-rule conflict.
/// * A genuinely transient/infrastructure failure stays [ErrorKind.transient]
///   (retryable), exactly as [PostgresConnection.query] classified it.
/// * A missing aggregate that a command referenced is an [ErrorKind.invariant]
///   precondition failure (`*.not_found`), not a transient miss — the caller
///   violated a business precondition by naming something that does not exist.
///
/// All queries bind values through `@named` parameters (Security ADR §2): no
/// untrusted value is ever concatenated into SQL.
final class PostgresCompetitionRepository implements CompetitionRepository {
  /// Creates the repository over an open [PostgresConnection].
  const PostgresCompetitionRepository(this._connection);

  final PostgresConnection _connection;

  // --------------------------------------------------------------------------
  // Competition
  // --------------------------------------------------------------------------

  static const String _insertCompetitionSql = '''
INSERT INTO competition.competitions (id, name, format, visibility)
VALUES (@id, @name, @format::competition.format_type,
        @visibility::competition.visibility)
''';

  @override
  Future<Result<void>> saveCompetition(Competition competition) async {
    final result = await _connection.query(
      _insertCompetitionSql,
      parameters: {
        'id': competition.id.value,
        'name': competition.name,
        'format': competition.format.wireValue,
        'visibility': competition.visibility.wireValue,
      },
    );
    return _asVoid(
      result,
      onConstraint: (name) => switch (name) {
        // Duplicate primary key — an astronomically unlikely id collision.
        'competitions_pkey' => const AppError.invariant(
          'competition.duplicate_id',
          'A competition with this id already exists',
        ),
        _ => null,
      },
    );
  }

  static const String _selectCompetitionSql = '''
SELECT id, name, format, visibility
FROM competition.competitions
WHERE id = @id
''';

  @override
  Future<Result<Competition>> findCompetition(CompetitionId id) async {
    final result = await _connection.query(
      _selectCompetitionSql,
      parameters: {'id': id.value},
    );
    return switch (result) {
      Err<List<Map<String, dynamic>>>(:final error) => Result.err(error),
      Ok<List<Map<String, dynamic>>>(:final value) =>
        value.isEmpty
            ? const Result.err(
                AppError.invariant(
                  'competition.not_found',
                  'Competition not found',
                ),
              )
            : _mapCompetition(value.first),
    };
  }

  // Browse read (BLOCKER FA-1): the discoverable catalogue — every PUBLIC
  // competition, ordered by name for a stable presentation. Private
  // competitions are omitted (no client-facing discovery yet; mirrors the
  // migration's `competitions_select_public` RLS backstop). A read path never
  // leaks a raw invariant: a corrupt row maps to transient `row_corrupt`.
  static const String _listCompetitionsSql = '''
SELECT id, name, format, visibility
FROM competition.competitions
WHERE visibility = 'public'::competition.visibility
ORDER BY name ASC, id ASC
''';

  @override
  Future<Result<List<Competition>>> listCompetitions() async {
    final result = await _connection.query(_listCompetitionsSql);
    return switch (result) {
      Err<List<Map<String, dynamic>>>(:final error) => Result.err(error),
      Ok<List<Map<String, dynamic>>>(:final value) => _mapAll(
        value,
        _mapCompetition,
      ),
    };
  }

  Result<Competition> _mapCompetition(Map<String, dynamic> row) {
    final idResult = CompetitionId.tryParse(row['id']?.toString());
    final formatResult = FormatType.tryParse(row['format']?.toString());
    final visibilityResult = CompetitionVisibility.tryParse(
      row['visibility']?.toString(),
    );
    final name = row['name'];

    if (idResult is Err<CompetitionId>) {
      return Result.err(_corrupt('competitions', 'id', idResult.error.message));
    }
    if (formatResult is Err<FormatType>) {
      return Result.err(
        _corrupt('competitions', 'format', formatResult.error.message),
      );
    }
    if (visibilityResult is Err<CompetitionVisibility>) {
      return Result.err(
        _corrupt('competitions', 'visibility', visibilityResult.error.message),
      );
    }
    if (name is! String) {
      return Result.err(_corrupt('competitions', 'name', 'not a string'));
    }

    return Result.ok(
      Competition.fromStored(
        id: (idResult as Ok<CompetitionId>).value,
        name: name,
        format: (formatResult as Ok<FormatType>).value,
        visibility: (visibilityResult as Ok<CompetitionVisibility>).value,
      ),
    );
  }

  // --------------------------------------------------------------------------
  // Season
  // --------------------------------------------------------------------------

  static const String _insertSeasonSql = '''
INSERT INTO competition.seasons (id, competition_id, label)
VALUES (@id, @competition_id, @label)
''';

  @override
  Future<Result<void>> saveSeason(CompetitionSeason season) async {
    final result = await _connection.query(
      _insertSeasonSql,
      parameters: {
        'id': season.id.value,
        'competition_id': season.competitionId.value,
        'label': season.label,
      },
    );
    return _asVoid(
      result,
      onConstraint: (name) => switch (name) {
        'seasons_pkey' => const AppError.invariant(
          'competition.duplicate_id',
          'A season with this id already exists',
        ),
        // FK to a competition that does not exist — a precondition the app
        // checks first; the constraint is the backstop.
        'seasons_competition_id_fkey' => const AppError.invariant(
          'competition.not_found',
          'Competition not found',
        ),
        _ => null,
      },
    );
  }

  static const String _selectSeasonSql = '''
SELECT id, competition_id, label
FROM competition.seasons
WHERE id = @id
''';

  @override
  Future<Result<CompetitionSeason>> findSeason(SeasonId id) async {
    final result = await _connection.query(
      _selectSeasonSql,
      parameters: {'id': id.value},
    );
    return switch (result) {
      Err<List<Map<String, dynamic>>>(:final error) => Result.err(error),
      Ok<List<Map<String, dynamic>>>(:final value) =>
        value.isEmpty
            ? const Result.err(
                AppError.invariant(
                  'competition.season_not_found',
                  'Season not found',
                ),
              )
            : _mapSeason(value.first),
    };
  }

  // Browse read (BLOCKER FA-1 / DEFECT AD-2): a competition's seasons ordered by
  // their display `label` (then id for a stable, total order — matching the
  // `ListCompetitionSeasons` use-case's documented order). An absent/empty
  // competition is a legitimate empty list (no existence oracle) — the SELECT
  // simply returns no rows. Reuses `_mapSeason` so a corrupt row maps to
  // transient `row_corrupt`, exactly as `findSeason` does.
  static const String _listCompetitionSeasonsSql = '''
SELECT id, competition_id, label
FROM competition.seasons
WHERE competition_id = @competition_id
ORDER BY label ASC, id ASC
''';

  @override
  Future<Result<List<CompetitionSeason>>> listCompetitionSeasons(
    CompetitionId competitionId,
  ) async {
    final result = await _connection.query(
      _listCompetitionSeasonsSql,
      parameters: {'competition_id': competitionId.value},
    );
    return switch (result) {
      Err<List<Map<String, dynamic>>>(:final error) => Result.err(error),
      Ok<List<Map<String, dynamic>>>(:final value) => _mapAll(
        value,
        _mapSeason,
      ),
    };
  }

  Result<CompetitionSeason> _mapSeason(Map<String, dynamic> row) {
    final idResult = SeasonId.tryParse(row['id']?.toString());
    final competitionIdResult = CompetitionId.tryParse(
      row['competition_id']?.toString(),
    );
    final label = row['label'];

    if (idResult is Err<SeasonId>) {
      return Result.err(_corrupt('seasons', 'id', idResult.error.message));
    }
    if (competitionIdResult is Err<CompetitionId>) {
      return Result.err(
        _corrupt(
          'seasons',
          'competition_id',
          competitionIdResult.error.message,
        ),
      );
    }
    if (label is! String) {
      return Result.err(_corrupt('seasons', 'label', 'not a string'));
    }

    return Result.ok(
      CompetitionSeason.fromStored(
        id: (idResult as Ok<SeasonId>).value,
        competitionId: (competitionIdResult as Ok<CompetitionId>).value,
        label: label,
      ),
    );
  }

  // --------------------------------------------------------------------------
  // Round
  // --------------------------------------------------------------------------

  static const String _insertRoundSql = '''
INSERT INTO competition.rounds
  (id, season_id, sequence, prediction_deadline, status,
   ruleset_snapshot, ruleset_version)
VALUES
  (@id, @season_id, @sequence, @prediction_deadline,
   @status::competition.round_status, @ruleset_snapshot::jsonb,
   @ruleset_version)
''';

  @override
  Future<Result<void>> saveRound(Round round) async {
    final result = await _connection.query(
      _insertRoundSql,
      parameters: {
        'id': round.id.value,
        'season_id': round.seasonId.value,
        'sequence': round.sequence,
        // The domain guarantees UTC; timestamptz stores the instant.
        'prediction_deadline': round.predictionDeadline.toIso8601String(),
        'status': round.status.wireValue,
        // JSONB written as canonical JSON text and cast server-side, so the
        // structured payload round-trips verbatim without depending on a
        // driver-specific typed-value wrapper.
        'ruleset_snapshot': jsonEncode(round.ruleset.payload),
        'ruleset_version': round.ruleset.rulesetVersion,
      },
    );
    return _asVoid(
      result,
      onConstraint: (name) => switch (name) {
        'rounds_pkey' => const AppError.invariant(
          'competition.duplicate_id',
          'A round with this id already exists',
        ),
        // A duplicate ordinal within a season — the founding round uniqueness.
        'rounds_season_sequence_uniq' => const AppError.invariant(
          'competition.round_sequence_conflict',
          'A round with this sequence already exists in the season',
        ),
        'rounds_season_id_fkey' => const AppError.invariant(
          'competition.season_not_found',
          'Season not found',
        ),
        _ => null,
      },
    );
  }

  static const String _selectRoundSql = '''
SELECT id, season_id, sequence, prediction_deadline, status,
       ruleset_snapshot, ruleset_version
FROM competition.rounds
WHERE id = @id
''';

  @override
  Future<Result<Round>> findRound(RoundId id) async {
    final result = await _connection.query(
      _selectRoundSql,
      parameters: {'id': id.value},
    );
    return switch (result) {
      Err<List<Map<String, dynamic>>>(:final error) => Result.err(error),
      Ok<List<Map<String, dynamic>>>(:final value) =>
        value.isEmpty
            ? const Result.err(
                AppError.invariant(
                  'competition.round_not_found',
                  'Round not found',
                ),
              )
            : _mapRound(value.first),
    };
  }

  // Browse read (BLOCKER FA-1): a season's rounds ordered by their 1-based
  // sequence. An absent/empty season is a legitimate empty list (no existence
  // oracle) — the SELECT simply returns no rows. Reuses `_mapRound` so a
  // corrupt row maps to transient `row_corrupt`, exactly as `findRound` does.
  static const String _listSeasonRoundsSql = '''
SELECT id, season_id, sequence, prediction_deadline, status,
       ruleset_snapshot, ruleset_version
FROM competition.rounds
WHERE season_id = @season_id
ORDER BY sequence ASC
''';

  @override
  Future<Result<List<Round>>> listSeasonRounds(SeasonId seasonId) async {
    final result = await _connection.query(
      _listSeasonRoundsSql,
      parameters: {'season_id': seasonId.value},
    );
    return switch (result) {
      Err<List<Map<String, dynamic>>>(:final error) => Result.err(error),
      Ok<List<Map<String, dynamic>>>(:final value) => _mapAll(value, _mapRound),
    };
  }

  Result<Round> _mapRound(Map<String, dynamic> row) {
    final idResult = RoundId.tryParse(row['id']?.toString());
    final seasonIdResult = SeasonId.tryParse(row['season_id']?.toString());
    final statusResult = RoundStatus.tryParse(row['status']?.toString());
    final sequence = row['sequence'];
    final deadlineRaw = row['prediction_deadline'];
    final rulesetVersion = row['ruleset_version'];

    if (idResult is Err<RoundId>) {
      return Result.err(_corrupt('rounds', 'id', idResult.error.message));
    }
    if (seasonIdResult is Err<SeasonId>) {
      return Result.err(
        _corrupt('rounds', 'season_id', seasonIdResult.error.message),
      );
    }
    if (statusResult is Err<RoundStatus>) {
      return Result.err(
        _corrupt('rounds', 'status', statusResult.error.message),
      );
    }
    if (sequence is! int) {
      return Result.err(_corrupt('rounds', 'sequence', 'not an integer'));
    }
    if (rulesetVersion is! int) {
      return Result.err(
        _corrupt('rounds', 'ruleset_version', 'not an integer'),
      );
    }

    final deadline = _readUtcTimestamp(deadlineRaw);
    if (deadline == null) {
      return Result.err(
        _corrupt('rounds', 'prediction_deadline', 'not a timestamp'),
      );
    }

    final payload = _readJsonObject(row['ruleset_snapshot']);
    if (payload == null) {
      return Result.err(
        _corrupt('rounds', 'ruleset_snapshot', 'not a JSON object'),
      );
    }

    final snapshotResult = RulesetSnapshot.create(
      payload: payload,
      rulesetVersion: rulesetVersion,
    );
    if (snapshotResult is Err<RulesetSnapshot>) {
      return Result.err(
        _corrupt('rounds', 'ruleset_snapshot', snapshotResult.error.message),
      );
    }

    return Result.ok(
      Round.fromStored(
        id: (idResult as Ok<RoundId>).value,
        seasonId: (seasonIdResult as Ok<SeasonId>).value,
        sequence: sequence,
        predictionDeadline: deadline,
        status: (statusResult as Ok<RoundStatus>).value,
        ruleset: (snapshotResult as Ok<RulesetSnapshot>).value,
      ),
    );
  }

  // Guarded status transition: keyed on the expected prior status so a
  // concurrent transition cannot be silently lost (optimistic concurrency —
  // the storage-layer backstop to Round.transitionTo). The `RETURNING` lets us
  // distinguish "no row updated" (a stale/lost race) from a driver error.
  static const String _updateRoundStatusSql = '''
UPDATE competition.rounds
SET status = @next::competition.round_status
WHERE id = @id
  AND status = @expected::competition.round_status
RETURNING id
''';

  @override
  Future<Result<void>> updateRoundStatus(
    Round round,
    RoundStatus expectedPriorStatus,
  ) async {
    final result = await _connection.query(
      _updateRoundStatusSql,
      parameters: {
        'id': round.id.value,
        'next': round.status.wireValue,
        'expected': expectedPriorStatus.wireValue,
      },
    );
    return switch (result) {
      Err<List<Map<String, dynamic>>>(:final error) => Result.err(
        _reclassify(error, onConstraint: (_) => null),
      ),
      // Zero rows updated: the stored status no longer matched the expected
      // prior status — a concurrent transition won the race. Surface as the
      // conflict the use-case documents.
      Ok<List<Map<String, dynamic>>>(:final value) =>
        value.isEmpty
            ? const Result.err(
                AppError.invariant(
                  'competition.round_transition_conflict',
                  'Round is no longer in the expected state; '
                      'a concurrent transition occurred',
                ),
              )
            : const Result.ok(null),
    };
  }

  // --------------------------------------------------------------------------
  // RoundFixture link
  // --------------------------------------------------------------------------

  static const String _insertRoundFixtureSql = '''
INSERT INTO competition.round_fixtures (round_id, fixture_id, display_order)
VALUES (@round_id, @fixture_id, @display_order)
''';

  @override
  Future<Result<void>> saveRoundFixture(RoundFixture link) async {
    final result = await _connection.query(
      _insertRoundFixtureSql,
      parameters: {
        'round_id': link.roundId.value,
        'fixture_id': link.fixture.value,
        'display_order': link.displayOrder,
      },
    );
    return _asVoid(
      result,
      onConstraint: (name) => switch (name) {
        // Composite PK (round_id, fixture_id): the fixture is already linked.
        'round_fixtures_pkey' => const AppError.invariant(
          'competition.fixture_already_linked',
          'This fixture is already linked to the round',
        ),
        'round_fixtures_round_id_fkey' => const AppError.invariant(
          'competition.round_not_found',
          'Round not found',
        ),
        _ => null,
      },
    );
  }

  // Browse read (BLOCKER FA-1): the fixtures linked to a round, in matchday
  // (`display_order`) order — the set a client renders to build the prediction
  // form. An absent/empty round is a legitimate empty list (no existence
  // oracle). A corrupt row maps to transient `row_corrupt`.
  static const String _listRoundFixturesSql = '''
SELECT round_id, fixture_id, display_order
FROM competition.round_fixtures
WHERE round_id = @round_id
ORDER BY display_order ASC, fixture_id ASC
''';

  @override
  Future<Result<List<RoundFixture>>> listRoundFixtures(RoundId roundId) async {
    final result = await _connection.query(
      _listRoundFixturesSql,
      parameters: {'round_id': roundId.value},
    );
    return switch (result) {
      Err<List<Map<String, dynamic>>>(:final error) => Result.err(error),
      Ok<List<Map<String, dynamic>>>(:final value) => _mapAll(
        value,
        _mapRoundFixture,
      ),
    };
  }

  Result<RoundFixture> _mapRoundFixture(Map<String, dynamic> row) {
    final roundIdResult = RoundId.tryParse(row['round_id']?.toString());
    final fixtureResult = FixtureRef.tryParse(row['fixture_id']?.toString());
    final displayOrder = row['display_order'];

    if (roundIdResult is Err<RoundId>) {
      return Result.err(
        _corrupt('round_fixtures', 'round_id', roundIdResult.error.message),
      );
    }
    if (fixtureResult is Err<FixtureRef>) {
      return Result.err(
        _corrupt('round_fixtures', 'fixture_id', fixtureResult.error.message),
      );
    }
    if (displayOrder is! int) {
      return Result.err(
        _corrupt('round_fixtures', 'display_order', 'not an integer'),
      );
    }

    return Result.ok(
      RoundFixture.fromStored(
        roundId: (roundIdResult as Ok<RoundId>).value,
        fixture: (fixtureResult as Ok<FixtureRef>).value,
        displayOrder: displayOrder,
      ),
    );
  }

  // --------------------------------------------------------------------------
  // Participant
  // --------------------------------------------------------------------------

  static const String _insertParticipantSql = '''
INSERT INTO competition.participants (id, season_id, user_id, status, joined_at)
VALUES (@id, @season_id, @user_id,
        @status::competition.participant_status, @joined_at)
''';

  @override
  Future<Result<void>> saveParticipant(Participant participant) async {
    final result = await _connection.query(
      _insertParticipantSql,
      parameters: {
        'id': participant.id.value,
        'season_id': participant.seasonId.value,
        'user_id': participant.userId.value,
        'status': participant.status.wireValue,
        'joined_at': participant.joinedAt.toIso8601String(),
      },
    );
    return _asVoid(
      result,
      onConstraint: (name) => switch (name) {
        // A user joins a season at most once — the join use-case treats this as
        // the idempotency backstop and re-reads the winning enrolment.
        'participants_season_user_uniq' => const AppError.invariant(
          'competition.already_joined',
          'User has already joined this season',
        ),
        'participants_pkey' => const AppError.invariant(
          'competition.duplicate_id',
          'A participant with this id already exists',
        ),
        'participants_season_id_fkey' => const AppError.invariant(
          'competition.season_not_found',
          'Season not found',
        ),
        'participants_user_id_fkey' => const AppError.invariant(
          'competition.user_not_found',
          'User not found',
        ),
        _ => null,
      },
    );
  }

  static const String _selectParticipantSql = '''
SELECT id, season_id, user_id, status, joined_at
FROM competition.participants
WHERE season_id = @season_id AND user_id = @user_id
''';

  @override
  Future<Result<Participant?>> findParticipant(
    SeasonId seasonId,
    UserId userId,
  ) async {
    final result = await _connection.query(
      _selectParticipantSql,
      parameters: {'season_id': seasonId.value, 'user_id': userId.value},
    );
    return switch (result) {
      Err<List<Map<String, dynamic>>>(:final error) => Result.err(error),
      // Absence is a normal, successful "not joined" outcome (Ok(null)), not an
      // error — the join use-case relies on this to decide idempotently.
      Ok<List<Map<String, dynamic>>>(:final value) =>
        value.isEmpty ? const Result.ok(null) : _mapParticipant(value.first),
    };
  }

  Result<Participant?> _mapParticipant(Map<String, dynamic> row) {
    final idResult = ParticipantId.tryParse(row['id']?.toString());
    final seasonIdResult = SeasonId.tryParse(row['season_id']?.toString());
    final userIdResult = UserId.tryParse(row['user_id']?.toString());
    final statusResult = ParticipantStatus.tryParse(row['status']?.toString());
    final joinedAt = _readUtcTimestamp(row['joined_at']);

    if (idResult is Err<ParticipantId>) {
      return Result.err(_corrupt('participants', 'id', idResult.error.message));
    }
    if (seasonIdResult is Err<SeasonId>) {
      return Result.err(
        _corrupt('participants', 'season_id', seasonIdResult.error.message),
      );
    }
    if (userIdResult is Err<UserId>) {
      return Result.err(
        _corrupt('participants', 'user_id', userIdResult.error.message),
      );
    }
    if (statusResult is Err<ParticipantStatus>) {
      return Result.err(
        _corrupt('participants', 'status', statusResult.error.message),
      );
    }
    if (joinedAt == null) {
      return Result.err(
        _corrupt('participants', 'joined_at', 'not a timestamp'),
      );
    }

    return Result.ok(
      Participant.fromStored(
        id: (idResult as Ok<ParticipantId>).value,
        seasonId: (seasonIdResult as Ok<SeasonId>).value,
        userId: (userIdResult as Ok<UserId>).value,
        status: (statusResult as Ok<ParticipantStatus>).value,
        joinedAt: joinedAt,
      ),
    );
  }

  // --------------------------------------------------------------------------
  // Shared helpers
  // --------------------------------------------------------------------------

  /// Maps every [rows] entry through [mapRow], short-circuiting on the first
  /// mapping failure (a corrupt row surfaces as the transient `row_corrupt` the
  /// per-aggregate mapper produces). Used by the browse list reads
  /// (BLOCKER FA-1) so a single bad row fails the read rather than silently
  /// dropping an item — a read path never fabricates a partial list.
  Result<List<T>> _mapAll<T>(
    List<Map<String, dynamic>> rows,
    Result<T> Function(Map<String, dynamic> row) mapRow,
  ) {
    final out = <T>[];
    for (final row in rows) {
      final mapped = mapRow(row);
      switch (mapped) {
        case Ok<T>(:final value):
          out.add(value);
        case Err<T>(:final error):
          return Result.err(error);
      }
    }
    return Result.ok(List<T>.unmodifiable(out));
  }

  /// Collapses a write query result to `Result<void>`, reclassifying a storage
  /// integrity violation to the domain [ErrorKind.invariant] the [onConstraint]
  /// resolver names for the violated constraint.
  Result<void> _asVoid(
    Result<List<Map<String, dynamic>>> result, {
    required AppError? Function(String constraint) onConstraint,
  }) {
    return switch (result) {
      Ok<List<Map<String, dynamic>>>() => const Result.ok(null),
      Err<List<Map<String, dynamic>>>(:final error) => Result.err(
        _reclassify(error, onConstraint: onConstraint),
      ),
    };
  }

  /// Reclassifies a [PostgresConnection]-produced transient error into an
  /// [ErrorKind.invariant] business conflict when its underlying cause is a
  /// storage-integrity violation the application could not pre-empt.
  ///
  /// `PostgresConnection.query` wraps any driver exception as
  /// `AppError.transient(cause: <exception>)`; here we inspect that cause. The
  /// `postgres` 3.5.x driver raises a [ServerException] carrying the SQLSTATE
  /// `code` and (for constraint failures) the `constraintName`; the specialized
  /// subtypes [UniqueViolationException]/[ForeignKeyViolationException] are also
  /// `ServerException`s, so matching the base type covers all of them.
  ///
  /// If the cause is not an integrity violation (or [onConstraint] declines to
  /// map the specific constraint), the original transient error is preserved —
  /// a real infrastructure fault stays retryable.
  AppError _reclassify(
    AppError error, {
    required AppError? Function(String constraint) onConstraint,
  }) {
    final cause = error.cause;
    if (cause is! ServerException) {
      return error;
    }
    final code = cause.code;
    // 23505 unique_violation, 23503 foreign_key_violation,
    // 23514 check_violation (our freeze/lifecycle triggers raise this).
    const integrityCodes = {'23505', '23503', '23514'};
    if (code == null || !integrityCodes.contains(code)) {
      return error;
    }

    final constraint = cause.constraintName;
    if (constraint != null) {
      final mapped = onConstraint(constraint);
      if (mapped != null) {
        return mapped;
      }
    }

    // A recognized integrity class we could not attribute to a named
    // constraint (e.g. a trigger-raised check_violation, which carries no
    // constraint name): still a business-rule conflict, not a transient fault.
    return AppError.invariant(
      'competition.integrity_violation',
      'The write violated a competition integrity rule',
    );
  }

  /// Reads a timestamp column into a UTC [DateTime]. The `postgres` driver
  /// returns `timestamptz` as a [DateTime]; we normalize to UTC. A stored ISO
  /// string is also accepted defensively.
  static DateTime? _readUtcTimestamp(Object? raw) {
    if (raw is DateTime) {
      return raw.toUtc();
    }
    if (raw is String) {
      final parsed = DateTime.tryParse(raw);
      return parsed?.toUtc();
    }
    return null;
  }

  /// Reads a JSONB column into a `Map<String, Object?>`. The driver decodes
  /// JSONB to a Dart `Map`; a stored JSON string is decoded defensively.
  static Map<String, Object?>? _readJsonObject(Object? raw) {
    if (raw is Map) {
      return raw.map((key, value) => MapEntry(key.toString(), value));
    }
    if (raw is String) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          return decoded.map((key, value) => MapEntry(key.toString(), value));
        }
      } on FormatException {
        return null;
      }
    }
    return null;
  }

  /// A stored row that fails to map indicates data corruption or schema drift —
  /// an infrastructure fault, surfaced as transient rather than blamed on the
  /// caller (mirrors `PostgresUserDirectory._corrupt`).
  static AppError _corrupt(String table, String field, String detail) =>
      AppError.transient(
        'competition.row_corrupt',
        'Stored $table row has invalid $field: $detail',
      );
}
