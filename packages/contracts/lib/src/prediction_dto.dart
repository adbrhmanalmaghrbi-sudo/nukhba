/// Versioned wire shapes for the Prediction context (API ADR §4: DTOs are
/// decoupled from the schema and carry a schema version so client and archived
/// payloads evolve safely; API ADR §2: commands speak in domain intents).
///
/// These are pure data shapes shared verbatim by client and server; this file
/// depends on nothing (Application ADR §3).
///
/// Integrity boundary (Axioms 2/5): the *command* shapes carry only the user's
/// intent (which fixtures, which scores). No DTO here carries points, a computed
/// score, or any competitive-record value — those are produced server-side by
/// the later Scoring phase and never round-trip through the client (a client
/// must never compute or submit points). The *read* shapes echo back only the
/// stored intent plus safe identity/structure facts.
library;

/// A single fixture's predicted scoreline on the wire — the football-seam shape
/// (Axiom 3: `football_scoreline`'s home/away score pair). Used inside both the
/// submit command and the read projection.
final class FixtureScoreDto {
  /// Creates a fixture-score DTO.
  const FixtureScoreDto({
    required this.fixtureId,
    required this.homeGoals,
    required this.awayGoals,
  });

  /// Deserializes from a JSON map.
  factory FixtureScoreDto.fromJson(Map<String, Object?> json) {
    return FixtureScoreDto(
      fixtureId: json['fixture_id']! as String,
      homeGoals: json['home_goals']! as int,
      awayGoals: json['away_goals']! as int,
    );
  }

  /// The referenced fixture id (UUID string; opaque Football-Data reference).
  final String fixtureId;

  /// The predicted goals for the home side.
  final int homeGoals;

  /// The predicted goals for the away side.
  final int awayGoals;

  /// Serializes to a JSON-encodable map.
  Map<String, Object?> toJson() => {
    'fixture_id': fixtureId,
    'home_goals': homeGoals,
    'away_goals': awayGoals,
  };

  @override
  bool operator ==(Object other) =>
      other is FixtureScoreDto &&
      other.fixtureId == fixtureId &&
      other.homeGoals == homeGoals &&
      other.awayGoals == awayGoals;

  @override
  int get hashCode => Object.hash(fixtureId, homeGoals, awayGoals);
}

/// The request body of `POST /rounds/{id}/predictions` — a `SubmitPrediction`
/// command (API ADR §2). The round is named in the path; the participant is
/// resolved server-side from the verified principal (never a body field, so a
/// caller can never predict on someone else's behalf — Security ADR §2 / Axiom
/// 2). The body therefore carries only the predicted scorelines.
final class SubmitPredictionCommandDto {
  /// Creates a submit-prediction command DTO.
  const SubmitPredictionCommandDto({
    required this.fixtureScores,
    this.schemaVersion = currentSchemaVersion,
  });

  /// Deserializes from a JSON map, defaulting [schemaVersion] for legacy
  /// payloads that predate the field.
  factory SubmitPredictionCommandDto.fromJson(Map<String, Object?> json) {
    final rawScores = json['fixture_scores']! as List<Object?>;
    return SubmitPredictionCommandDto(
      schemaVersion: (json['schema_version'] as int?) ?? 1,
      fixtureScores: rawScores
          .map(
            (e) => FixtureScoreDto.fromJson(
              (e! as Map<Object?, Object?>).cast<String, Object?>(),
            ),
          )
          .toList(growable: false),
    );
  }

  /// The current schema version for this DTO.
  static const int currentSchemaVersion = 1;

  /// The predicted scorelines, one per fixture in the round the caller predicts.
  final List<FixtureScoreDto> fixtureScores;

  /// The schema version of this payload.
  final int schemaVersion;

  /// Serializes to a JSON-encodable map.
  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'fixture_scores': [for (final s in fixtureScores) s.toJson()],
  };

  @override
  bool operator ==(Object other) =>
      other is SubmitPredictionCommandDto &&
      _listEquals(other.fixtureScores, fixtureScores) &&
      other.schemaVersion == schemaVersion;

  @override
  int get hashCode => Object.hash(Object.hashAll(fixtureScores), schemaVersion);

  static bool _listEquals(List<FixtureScoreDto> a, List<FixtureScoreDto> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// The wire shape of a stored prediction (read projection).
///
/// Carries the participant + round binding, the submission instant, and the
/// predicted scorelines — the user's intent, echoed back. It deliberately
/// excludes any points/score/competitive-record value (those are Scoring/Ledger
/// concerns, computed server-side, and never part of the prediction read model).
final class PredictionDto {
  /// Creates a prediction DTO.
  const PredictionDto({
    required this.id,
    required this.participantId,
    required this.roundId,
    required this.submittedAt,
    required this.fixtureScores,
    this.schemaVersion = currentSchemaVersion,
  });

  /// Deserializes from a JSON map, defaulting [schemaVersion] for legacy
  /// payloads that predate the field.
  factory PredictionDto.fromJson(Map<String, Object?> json) {
    final rawScores = json['fixture_scores']! as List<Object?>;
    return PredictionDto(
      schemaVersion: (json['schema_version'] as int?) ?? 1,
      id: json['id']! as String,
      participantId: json['participant_id']! as String,
      roundId: json['round_id']! as String,
      submittedAt: json['submitted_at']! as String,
      fixtureScores: rawScores
          .map(
            (e) => FixtureScoreDto.fromJson(
              (e! as Map<Object?, Object?>).cast<String, Object?>(),
            ),
          )
          .toList(growable: false),
    );
  }

  /// The current schema version for this DTO.
  static const int currentSchemaVersion = 1;

  /// The prediction id (UUID string).
  final String id;

  /// The owning participant id (UUID string).
  final String participantId;

  /// The round id (UUID string).
  final String roundId;

  /// The submission instant as an ISO-8601 UTC string.
  final String submittedAt;

  /// The predicted scorelines.
  final List<FixtureScoreDto> fixtureScores;

  /// The schema version of this payload.
  final int schemaVersion;

  /// Serializes to a JSON-encodable map.
  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'id': id,
    'participant_id': participantId,
    'round_id': roundId,
    'submitted_at': submittedAt,
    'fixture_scores': [for (final s in fixtureScores) s.toJson()],
  };

  @override
  bool operator ==(Object other) =>
      other is PredictionDto &&
      other.id == id &&
      other.participantId == participantId &&
      other.roundId == roundId &&
      other.submittedAt == submittedAt &&
      _listEquals(other.fixtureScores, fixtureScores) &&
      other.schemaVersion == schemaVersion;

  @override
  int get hashCode => Object.hash(
    id,
    participantId,
    roundId,
    submittedAt,
    Object.hashAll(fixtureScores),
    schemaVersion,
  );

  static bool _listEquals(List<FixtureScoreDto> a, List<FixtureScoreDto> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
