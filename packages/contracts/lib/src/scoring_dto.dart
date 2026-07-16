/// Versioned wire shapes for the Scoring context (API ADR §4: DTOs are decoupled
/// from the schema and carry a schema version so client and archived payloads
/// evolve safely).
///
/// These are pure data shapes shared verbatim by client and server; this file
/// depends on nothing (Application ADR §3).
///
/// Integrity boundary (Axioms 2/5): scoring is a **read-only** surface on the
/// wire. Points and grades here are a server-produced read projection — the
/// client never computes or submits them, and there is deliberately **no**
/// command DTO in this file (a round is scored by an admin command whose body
/// carries no points; see the server route). The read shapes echo back the
/// server-computed grade and points for a round, keyed by id only (Axiom 3: the
/// football seam names a fixture by id; Axiom 4: a score carries no group ref).
library;

/// The wire shape echoed back after an admin ingests a fixture's actual result
/// (the response of `PUT /fixtures/{id}/result`; read projection of the domain
/// `FixtureResult`, the Axiom-3 football seam).
///
/// Deliberately the same shape as a predicted score — a pair of non-negative
/// goal tallies keyed by fixture id — since scoring compares two
/// identically-shaped outcomes. It carries **no** competition/round/participant
/// reference (Axiom 3: a fixture is competition-unaware) and no points (Axioms
/// 2/5: this is the actual result, not a score). Versioned for safe evolution.
final class FixtureResultDto {
  /// Creates a fixture-result DTO.
  const FixtureResultDto({
    required this.fixtureId,
    required this.homeGoals,
    required this.awayGoals,
    this.schemaVersion = currentSchemaVersion,
  });

  /// Deserializes from a JSON map, defaulting [schemaVersion] for legacy
  /// payloads that predate the field.
  factory FixtureResultDto.fromJson(Map<String, Object?> json) {
    return FixtureResultDto(
      schemaVersion: (json['schema_version'] as int?) ?? 1,
      fixtureId: json['fixture_id']! as String,
      homeGoals: json['home_goals']! as int,
      awayGoals: json['away_goals']! as int,
    );
  }

  /// The current schema version for this DTO.
  static const int currentSchemaVersion = 1;

  /// The referenced fixture id (UUID string; opaque Football-Data reference).
  final String fixtureId;

  /// The actual number of goals the home side scored (non-negative).
  final int homeGoals;

  /// The actual number of goals the away side scored (non-negative).
  final int awayGoals;

  /// The schema version of this payload.
  final int schemaVersion;

  /// Serializes to a JSON-encodable map.
  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'fixture_id': fixtureId,
    'home_goals': homeGoals,
    'away_goals': awayGoals,
  };

  @override
  bool operator ==(Object other) =>
      other is FixtureResultDto &&
      other.fixtureId == fixtureId &&
      other.homeGoals == homeGoals &&
      other.awayGoals == awayGoals &&
      other.schemaVersion == schemaVersion;

  @override
  int get hashCode =>
      Object.hash(fixtureId, homeGoals, awayGoals, schemaVersion);
}

/// One fixture's server-computed grade and points on the wire — a pure read
/// value (Axioms 2/5: the client never produces this). Names the fixture by id
/// only (Axiom 3). The [grade] is the stable storage/wire token
/// (`exact_scoreline` / `correct_outcome` / `incorrect`), never a Dart enum
/// name, so a persisted value can never drift silently.
final class FixtureScoreResultDto {
  /// Creates a fixture-score-result DTO.
  const FixtureScoreResultDto({
    required this.fixtureId,
    required this.grade,
    required this.points,
  });

  /// Deserializes from a JSON map.
  factory FixtureScoreResultDto.fromJson(Map<String, Object?> json) {
    return FixtureScoreResultDto(
      fixtureId: json['fixture_id']! as String,
      grade: json['grade']! as String,
      points: json['points']! as int,
    );
  }

  /// The referenced fixture id (UUID string; opaque Football-Data reference).
  final String fixtureId;

  /// The grade wire token: `exact_scoreline`, `correct_outcome`, or
  /// `incorrect`. Matches `FixtureScoreGrade.wireValue` in the domain.
  final String grade;

  /// The server-computed points awarded for this fixture under the round's
  /// frozen ruleset (non-negative).
  final int points;

  /// Serializes to a JSON-encodable map.
  Map<String, Object?> toJson() => {
    'fixture_id': fixtureId,
    'grade': grade,
    'points': points,
  };

  @override
  bool operator ==(Object other) =>
      other is FixtureScoreResultDto &&
      other.fixtureId == fixtureId &&
      other.grade == grade &&
      other.points == points;

  @override
  int get hashCode => Object.hash(fixtureId, grade, points);
}

/// The wire shape of one participant's scored result for a round (read
/// projection of the domain `RoundScore`).
///
/// Carries the (participant, round) binding, the [rulesetVersion] that governed
/// the scoring (so a score can be traced to the exact frozen rules — Axiom 5),
/// the derived [totalPoints], and the ordered per-fixture breakdown. It carries
/// **no** group reference (Axiom 4) and no client-writable field: every value
/// here is server-computed.
final class RoundScoreDto {
  /// Creates a round-score DTO.
  const RoundScoreDto({
    required this.roundId,
    required this.participantId,
    required this.rulesetVersion,
    required this.totalPoints,
    required this.fixtureResults,
    this.schemaVersion = currentSchemaVersion,
  });

  /// Deserializes from a JSON map, defaulting [schemaVersion] for legacy
  /// payloads that predate the field.
  factory RoundScoreDto.fromJson(Map<String, Object?> json) {
    final rawResults = json['fixture_results']! as List<Object?>;
    return RoundScoreDto(
      schemaVersion: (json['schema_version'] as int?) ?? 1,
      roundId: json['round_id']! as String,
      participantId: json['participant_id']! as String,
      rulesetVersion: json['ruleset_version']! as int,
      totalPoints: json['total_points']! as int,
      fixtureResults: rawResults
          .map(
            (e) => FixtureScoreResultDto.fromJson(
              (e! as Map<Object?, Object?>).cast<String, Object?>(),
            ),
          )
          .toList(growable: false),
    );
  }

  /// The current schema version for this DTO.
  static const int currentSchemaVersion = 1;

  /// The round this score is for (UUID string).
  final String roundId;

  /// The owning participant id (UUID string).
  final String participantId;

  /// The version of the frozen ruleset used to compute this score.
  final int rulesetVersion;

  /// The server-derived sum of every fixture's points.
  final int totalPoints;

  /// The per-fixture breakdown, in the order the prediction listed its fixtures.
  final List<FixtureScoreResultDto> fixtureResults;

  /// The schema version of this payload.
  final int schemaVersion;

  /// Serializes to a JSON-encodable map.
  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'round_id': roundId,
    'participant_id': participantId,
    'ruleset_version': rulesetVersion,
    'total_points': totalPoints,
    'fixture_results': [for (final r in fixtureResults) r.toJson()],
  };

  @override
  bool operator ==(Object other) =>
      other is RoundScoreDto &&
      other.roundId == roundId &&
      other.participantId == participantId &&
      other.rulesetVersion == rulesetVersion &&
      other.totalPoints == totalPoints &&
      _listEquals(other.fixtureResults, fixtureResults) &&
      other.schemaVersion == schemaVersion;

  @override
  int get hashCode => Object.hash(
    roundId,
    participantId,
    rulesetVersion,
    totalPoints,
    Object.hashAll(fixtureResults),
    schemaVersion,
  );

  static bool _listEquals(
    List<FixtureScoreResultDto> a,
    List<FixtureScoreResultDto> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// The wire shape of the scored-results read for a whole round: the round id and
/// every participant's [RoundScoreDto] (the response of
/// `GET /rounds/{id}/scores`). A pure read projection — visibility gating (only
/// a `scored` round is exposed) lives in the use-case, not this shape.
final class RoundScoresDto {
  /// Creates a round-scores DTO.
  const RoundScoresDto({
    required this.roundId,
    required this.scores,
    this.schemaVersion = currentSchemaVersion,
  });

  /// Deserializes from a JSON map, defaulting [schemaVersion] for legacy
  /// payloads that predate the field.
  factory RoundScoresDto.fromJson(Map<String, Object?> json) {
    final rawScores = json['scores']! as List<Object?>;
    return RoundScoresDto(
      schemaVersion: (json['schema_version'] as int?) ?? 1,
      roundId: json['round_id']! as String,
      scores: rawScores
          .map(
            (e) => RoundScoreDto.fromJson(
              (e! as Map<Object?, Object?>).cast<String, Object?>(),
            ),
          )
          .toList(growable: false),
    );
  }

  /// The current schema version for this DTO.
  static const int currentSchemaVersion = 1;

  /// The round these scores are for (UUID string).
  final String roundId;

  /// Every participant's scored result for the round.
  final List<RoundScoreDto> scores;

  /// The schema version of this payload.
  final int schemaVersion;

  /// Serializes to a JSON-encodable map.
  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'round_id': roundId,
    'scores': [for (final s in scores) s.toJson()],
  };

  @override
  bool operator ==(Object other) =>
      other is RoundScoresDto &&
      other.roundId == roundId &&
      _listEquals(other.scores, scores) &&
      other.schemaVersion == schemaVersion;

  @override
  int get hashCode =>
      Object.hash(roundId, Object.hashAll(scores), schemaVersion);

  static bool _listEquals(List<RoundScoreDto> a, List<RoundScoreDto> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
