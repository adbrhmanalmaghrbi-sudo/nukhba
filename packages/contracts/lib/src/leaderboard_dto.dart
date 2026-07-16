/// Versioned wire shapes for the Leaderboards context (API ADR §4: DTOs are
/// decoupled from the schema and carry a schema version so client and archived
/// payloads evolve safely).
///
/// These are pure data shapes shared verbatim by client and server; this file
/// depends on nothing (Application ADR §3).
///
/// Integrity boundary (Axioms 2/5): a leaderboard is a **read-only** surface on
/// the wire — a server-produced projection over the append-only ledger. Totals
/// and ranks here are computed by the server; the client never submits or
/// computes a point total, and there is deliberately **no** command DTO in this
/// file (a leaderboard is only ever read). The entry shapes name a participant
/// by id only (Axiom 4: one score, ranked everywhere — no group reference on the
/// entry itself; a group/global board is a later phase over the same shape).
library;

/// The wire shape of one participant's line on a season leaderboard (read
/// projection of the domain `LeaderboardEntry`).
///
/// Names the participant by id only; carries the standard-competition
/// [rank] ("1224": tied totals share a rank, the next distinct total skips), the
/// signed [totalPoints] (equals that participant's ledger balance — a
/// `correction` is already netted in, so it may be negative — Axiom 5), and the
/// [entryCount] of immutable ledger movements the total sums (audit). Every
/// field is server-produced; none is client-writable (Axioms 2/5). Versioned.
final class LeaderboardEntryDto {
  /// Creates a leaderboard-entry DTO.
  const LeaderboardEntryDto({
    required this.rank,
    required this.participantId,
    required this.totalPoints,
    required this.entryCount,
    this.schemaVersion = currentSchemaVersion,
  });

  /// Deserializes from a JSON map, defaulting [schemaVersion] for legacy
  /// payloads that predate the field.
  factory LeaderboardEntryDto.fromJson(Map<String, Object?> json) {
    return LeaderboardEntryDto(
      schemaVersion: (json['schema_version'] as int?) ?? 1,
      rank: json['rank']! as int,
      participantId: json['participant_id']! as String,
      totalPoints: json['total_points']! as int,
      entryCount: json['entry_count']! as int,
    );
  }

  /// The current schema version for this DTO.
  static const int currentSchemaVersion = 1;

  /// The participant's standard-competition rank (1-based; tied totals share a
  /// rank, the next distinct total skips by the number tied).
  final int rank;

  /// The owning participant id (UUID string).
  final String participantId;

  /// The signed point total — the server projection over the participant's
  /// append-only ledger stream (equals their balance; may be negative if a
  /// correction nets below zero — Axiom 5).
  final int totalPoints;

  /// How many immutable ledger movements contributed to [totalPoints] (audit).
  final int entryCount;

  /// The schema version of this payload.
  final int schemaVersion;

  /// Serializes to a JSON-encodable map.
  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'rank': rank,
    'participant_id': participantId,
    'total_points': totalPoints,
    'entry_count': entryCount,
  };

  @override
  bool operator ==(Object other) =>
      other is LeaderboardEntryDto &&
      other.rank == rank &&
      other.participantId == participantId &&
      other.totalPoints == totalPoints &&
      other.entryCount == entryCount &&
      other.schemaVersion == schemaVersion;

  @override
  int get hashCode =>
      Object.hash(rank, participantId, totalPoints, entryCount, schemaVersion);
}

/// The wire shape of a season's ranked standings (read projection of the domain
/// `SeasonLeaderboard`) — the response of `GET /seasons/{id}/leaderboard`.
///
/// Names the season by id and carries the [entries] in the server-defined
/// display order (points descending, then joinedAt ascending, then participant
/// id ascending — a total, reproducible order). An **empty** [entries] list is a
/// legitimate result: a season with no participants. Visibility gating
/// (season-membership) lives in the use-case, not this shape. Versioned.
final class SeasonLeaderboardDto {
  /// Creates a season-leaderboard DTO.
  const SeasonLeaderboardDto({
    required this.seasonId,
    required this.entries,
    this.schemaVersion = currentSchemaVersion,
  });

  /// Deserializes from a JSON map, defaulting [schemaVersion] for legacy
  /// payloads that predate the field.
  factory SeasonLeaderboardDto.fromJson(Map<String, Object?> json) {
    final raw = json['entries']! as List<Object?>;
    return SeasonLeaderboardDto(
      schemaVersion: (json['schema_version'] as int?) ?? 1,
      seasonId: json['season_id']! as String,
      entries: raw
          .map(
            (e) => LeaderboardEntryDto.fromJson(
              (e! as Map<Object?, Object?>).cast<String, Object?>(),
            ),
          )
          .toList(growable: false),
    );
  }

  /// The current schema version for this DTO.
  static const int currentSchemaVersion = 1;

  /// The season these standings are for (UUID string).
  final String seasonId;

  /// The ranked entries, in the server-defined display order.
  final List<LeaderboardEntryDto> entries;

  /// The schema version of this payload.
  final int schemaVersion;

  /// Serializes to a JSON-encodable map.
  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'season_id': seasonId,
    'entries': [for (final e in entries) e.toJson()],
  };

  @override
  bool operator ==(Object other) =>
      other is SeasonLeaderboardDto &&
      other.seasonId == seasonId &&
      _listEquals(other.entries, entries) &&
      other.schemaVersion == schemaVersion;

  @override
  int get hashCode =>
      Object.hash(seasonId, Object.hashAll(entries), schemaVersion);

  static bool _listEquals(
    List<LeaderboardEntryDto> a,
    List<LeaderboardEntryDto> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
