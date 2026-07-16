/// Versioned wire shapes for the Competition context (API ADR, Section 4: DTOs
/// are decoupled from the schema and carry a schema version so client and
/// archived payloads evolve safely).
///
/// These are pure data shapes shared verbatim by client and server; this file
/// depends on nothing (Application ADR, Section 3). They are *read* projections
/// — a command handler returns them, a client renders them — and deliberately
/// carry only stable, safe identity/structure facts, never internal state.
library;

/// The wire shape of a competition (read projection).
final class CompetitionDto {
  /// Creates a competition DTO.
  const CompetitionDto({
    required this.id,
    required this.name,
    required this.format,
    required this.visibility,
    this.schemaVersion = currentSchemaVersion,
  });

  /// Deserializes from a JSON map, defaulting [schemaVersion] for legacy
  /// payloads that predate the field.
  factory CompetitionDto.fromJson(Map<String, Object?> json) {
    return CompetitionDto(
      schemaVersion: (json['schema_version'] as int?) ?? 1,
      id: json['id']! as String,
      name: json['name']! as String,
      format: json['format']! as String,
      visibility: json['visibility']! as String,
    );
  }

  /// The current schema version for this DTO.
  static const int currentSchemaVersion = 1;

  /// The competition id (UUID string).
  final String id;

  /// The display name.
  final String name;

  /// The game-format token (e.g. `football_scoreline`).
  final String format;

  /// The visibility token (`public` / `private`).
  final String visibility;

  /// The schema version of this payload.
  final int schemaVersion;

  /// Serializes to a JSON-encodable map.
  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'id': id,
    'name': name,
    'format': format,
    'visibility': visibility,
  };

  @override
  bool operator ==(Object other) =>
      other is CompetitionDto &&
      other.id == id &&
      other.name == name &&
      other.format == format &&
      other.visibility == visibility &&
      other.schemaVersion == schemaVersion;

  @override
  int get hashCode => Object.hash(id, name, format, visibility, schemaVersion);
}

/// The wire shape of a competition season (read projection).
final class SeasonDto {
  /// Creates a season DTO.
  const SeasonDto({
    required this.id,
    required this.competitionId,
    required this.label,
    this.schemaVersion = currentSchemaVersion,
  });

  /// Deserializes from a JSON map.
  factory SeasonDto.fromJson(Map<String, Object?> json) {
    return SeasonDto(
      schemaVersion: (json['schema_version'] as int?) ?? 1,
      id: json['id']! as String,
      competitionId: json['competition_id']! as String,
      label: json['label']! as String,
    );
  }

  /// The current schema version for this DTO.
  static const int currentSchemaVersion = 1;

  /// The season id (UUID string).
  final String id;

  /// The owning competition id (UUID string).
  final String competitionId;

  /// The display label (e.g. "2026/27").
  final String label;

  /// The schema version of this payload.
  final int schemaVersion;

  /// Serializes to a JSON-encodable map.
  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'id': id,
    'competition_id': competitionId,
    'label': label,
  };

  @override
  bool operator ==(Object other) =>
      other is SeasonDto &&
      other.id == id &&
      other.competitionId == competitionId &&
      other.label == label &&
      other.schemaVersion == schemaVersion;

  @override
  int get hashCode => Object.hash(id, competitionId, label, schemaVersion);
}

/// The wire shape of a round (read projection).
///
/// Intentionally excludes the frozen ruleset snapshot: the snapshot is an
/// internal, Scoring-owned structure (Application ADR, Section 2.10), not part
/// of the client-facing round read model. Only the ruleset *version* is exposed
/// so a client can display "rules v3" without receiving the opaque payload.
final class RoundDto {
  /// Creates a round DTO.
  const RoundDto({
    required this.id,
    required this.seasonId,
    required this.sequence,
    required this.predictionDeadline,
    required this.status,
    required this.rulesetVersion,
    this.schemaVersion = currentSchemaVersion,
  });

  /// Deserializes from a JSON map.
  factory RoundDto.fromJson(Map<String, Object?> json) {
    return RoundDto(
      schemaVersion: (json['schema_version'] as int?) ?? 1,
      id: json['id']! as String,
      seasonId: json['season_id']! as String,
      sequence: json['sequence']! as int,
      predictionDeadline: json['prediction_deadline']! as String,
      status: json['status']! as String,
      rulesetVersion: json['ruleset_version']! as int,
    );
  }

  /// The current schema version for this DTO.
  static const int currentSchemaVersion = 1;

  /// The round id (UUID string).
  final String id;

  /// The owning season id (UUID string).
  final String seasonId;

  /// The 1-based ordinal within the season.
  final int sequence;

  /// The prediction deadline as an ISO-8601 UTC string.
  final String predictionDeadline;

  /// The lifecycle status token (`open` / `locked` / `scored`).
  final String status;

  /// The version of the ruleset frozen for this round.
  final int rulesetVersion;

  /// The schema version of this payload.
  final int schemaVersion;

  /// Serializes to a JSON-encodable map.
  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'id': id,
    'season_id': seasonId,
    'sequence': sequence,
    'prediction_deadline': predictionDeadline,
    'status': status,
    'ruleset_version': rulesetVersion,
  };

  @override
  bool operator ==(Object other) =>
      other is RoundDto &&
      other.id == id &&
      other.seasonId == seasonId &&
      other.sequence == sequence &&
      other.predictionDeadline == predictionDeadline &&
      other.status == status &&
      other.rulesetVersion == rulesetVersion &&
      other.schemaVersion == schemaVersion;

  @override
  int get hashCode => Object.hash(
    id,
    seasonId,
    sequence,
    predictionDeadline,
    status,
    rulesetVersion,
    schemaVersion,
  );
}

/// The wire shape of a participant enrolment (read projection).
final class ParticipantDto {
  /// Creates a participant DTO.
  const ParticipantDto({
    required this.id,
    required this.seasonId,
    required this.userId,
    required this.status,
    required this.joinedAt,
    this.schemaVersion = currentSchemaVersion,
  });

  /// Deserializes from a JSON map.
  factory ParticipantDto.fromJson(Map<String, Object?> json) {
    return ParticipantDto(
      schemaVersion: (json['schema_version'] as int?) ?? 1,
      id: json['id']! as String,
      seasonId: json['season_id']! as String,
      userId: json['user_id']! as String,
      status: json['status']! as String,
      joinedAt: json['joined_at']! as String,
    );
  }

  /// The current schema version for this DTO.
  static const int currentSchemaVersion = 1;

  /// The participant id (UUID string).
  final String id;

  /// The season id (UUID string).
  final String seasonId;

  /// The enrolled user id (UUID string).
  final String userId;

  /// The enrolment status token (`active` / `withdrawn`).
  final String status;

  /// The enrolment instant as an ISO-8601 UTC string.
  final String joinedAt;

  /// The schema version of this payload.
  final int schemaVersion;

  /// Serializes to a JSON-encodable map.
  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'id': id,
    'season_id': seasonId,
    'user_id': userId,
    'status': status,
    'joined_at': joinedAt,
  };

  @override
  bool operator ==(Object other) =>
      other is ParticipantDto &&
      other.id == id &&
      other.seasonId == seasonId &&
      other.userId == userId &&
      other.status == status &&
      other.joinedAt == joinedAt &&
      other.schemaVersion == schemaVersion;

  @override
  int get hashCode =>
      Object.hash(id, seasonId, userId, status, joinedAt, schemaVersion);
}

/// The wire shape of a round↔fixture link (read projection).
final class RoundFixtureDto {
  /// Creates a round-fixture link DTO.
  const RoundFixtureDto({
    required this.roundId,
    required this.fixtureId,
    required this.displayOrder,
    this.schemaVersion = currentSchemaVersion,
  });

  /// Deserializes from a JSON map.
  factory RoundFixtureDto.fromJson(Map<String, Object?> json) {
    return RoundFixtureDto(
      schemaVersion: (json['schema_version'] as int?) ?? 1,
      roundId: json['round_id']! as String,
      fixtureId: json['fixture_id']! as String,
      displayOrder: json['display_order']! as int,
    );
  }

  /// The current schema version for this DTO.
  static const int currentSchemaVersion = 1;

  /// The owning round id (UUID string).
  final String roundId;

  /// The referenced fixture id (UUID string).
  final String fixtureId;

  /// The 0-based presentation order within the round.
  final int displayOrder;

  /// The schema version of this payload.
  final int schemaVersion;

  /// Serializes to a JSON-encodable map.
  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'round_id': roundId,
    'fixture_id': fixtureId,
    'display_order': displayOrder,
  };

  @override
  bool operator ==(Object other) =>
      other is RoundFixtureDto &&
      other.roundId == roundId &&
      other.fixtureId == fixtureId &&
      other.displayOrder == displayOrder &&
      other.schemaVersion == schemaVersion;

  @override
  int get hashCode =>
      Object.hash(roundId, fixtureId, displayOrder, schemaVersion);
}
