/// Versioned wire shapes for the Ledger context (API ADR §4: DTOs are decoupled
/// from the schema and carry a schema version so client and archived payloads
/// evolve safely).
///
/// These are pure data shapes shared verbatim by client and server; this file
/// depends on nothing (Application ADR §3).
///
/// Integrity boundary (Axioms 2/5): the ledger is a **read-only** surface on the
/// wire. Point amounts and balances here are a server-produced projection over
/// the append-only `PointEntry` stream — the client never computes or submits a
/// point amount, and there is deliberately **no** command DTO carrying a point
/// value in this file. The command that posts a scored round to the ledger
/// (`POST /rounds/{id}/ledger`) has NO request body; its response is the
/// [PostRoundToLedgerResponseDto] read shape. The entry/balance shapes name a
/// participant and round by id only (Axiom 4: no group reference).
library;

/// The wire shape of one immutable ledger movement (read projection of the
/// domain `PointEntry`).
///
/// Names the participant and round by id only; carries the signed [amount]
/// (a `round_score` credit is non-negative; a `correction` may be negative),
/// the [kind] wire token (`round_score` / `correction`, matching
/// `EntryKind.wireValue` — never a Dart enum name, so a persisted value can
/// never drift silently), the [sourceRef] provenance, and the [occurredAt]
/// instant (ISO-8601 UTC). Every field is server-produced; none is
/// client-writable (Axioms 2/5). Versioned for safe evolution.
final class PointEntryDto {
  /// Creates a point-entry DTO.
  const PointEntryDto({
    required this.id,
    required this.participantId,
    required this.roundId,
    required this.kind,
    required this.amount,
    required this.sourceRef,
    required this.occurredAt,
    this.schemaVersion = currentSchemaVersion,
  });

  /// Deserializes from a JSON map, defaulting [schemaVersion] for legacy
  /// payloads that predate the field.
  factory PointEntryDto.fromJson(Map<String, Object?> json) {
    return PointEntryDto(
      schemaVersion: (json['schema_version'] as int?) ?? 1,
      id: json['id']! as String,
      participantId: json['participant_id']! as String,
      roundId: json['round_id']! as String,
      kind: json['kind']! as String,
      amount: json['amount']! as int,
      sourceRef: json['source_ref']! as String,
      occurredAt: json['occurred_at']! as String,
    );
  }

  /// The current schema version for this DTO.
  static const int currentSchemaVersion = 1;

  /// The entry's own id (UUID string).
  final String id;

  /// The owning participant id (UUID string).
  final String participantId;

  /// The round this movement derives from (UUID string).
  final String roundId;

  /// The entry-kind wire token: `round_score` or `correction`. Matches
  /// `EntryKind.wireValue` in the domain.
  final String kind;

  /// The signed point movement (server-computed).
  final int amount;

  /// The provenance handle (originating scored round, or a correction's
  /// justification reference).
  final String sourceRef;

  /// When the movement occurred (ISO-8601 UTC string).
  final String occurredAt;

  /// The schema version of this payload.
  final int schemaVersion;

  /// Serializes to a JSON-encodable map.
  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'id': id,
    'participant_id': participantId,
    'round_id': roundId,
    'kind': kind,
    'amount': amount,
    'source_ref': sourceRef,
    'occurred_at': occurredAt,
  };

  @override
  bool operator ==(Object other) =>
      other is PointEntryDto &&
      other.id == id &&
      other.participantId == participantId &&
      other.roundId == roundId &&
      other.kind == kind &&
      other.amount == amount &&
      other.sourceRef == sourceRef &&
      other.occurredAt == occurredAt &&
      other.schemaVersion == schemaVersion;

  @override
  int get hashCode => Object.hash(
    id,
    participantId,
    roundId,
    kind,
    amount,
    sourceRef,
    occurredAt,
    schemaVersion,
  );
}

/// The wire shape of a participant's projected balance (read projection of the
/// domain `LedgerBalance`) — the response of `GET /participants/{id}/balance`.
///
/// The [balance] is a server-computed projection over the append-only entry
/// stream (never a client-writable number — Axiom 5); [entryCount] records how
/// many immutable movements it sums (audit). Names the participant by id only
/// (Axiom 4). Versioned for safe evolution.
final class BalanceDto {
  /// Creates a balance DTO.
  const BalanceDto({
    required this.participantId,
    required this.balance,
    required this.entryCount,
    this.schemaVersion = currentSchemaVersion,
  });

  /// Deserializes from a JSON map, defaulting [schemaVersion] for legacy
  /// payloads that predate the field.
  factory BalanceDto.fromJson(Map<String, Object?> json) {
    return BalanceDto(
      schemaVersion: (json['schema_version'] as int?) ?? 1,
      participantId: json['participant_id']! as String,
      balance: json['balance']! as int,
      entryCount: json['entry_count']! as int,
    );
  }

  /// The current schema version for this DTO.
  static const int currentSchemaVersion = 1;

  /// The participant this balance is projected for (UUID string).
  final String participantId;

  /// The server-projected signed balance.
  final int balance;

  /// How many immutable entries contributed to the projection.
  final int entryCount;

  /// The schema version of this payload.
  final int schemaVersion;

  /// Serializes to a JSON-encodable map.
  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'participant_id': participantId,
    'balance': balance,
    'entry_count': entryCount,
  };

  @override
  bool operator ==(Object other) =>
      other is BalanceDto &&
      other.participantId == participantId &&
      other.balance == balance &&
      other.entryCount == entryCount &&
      other.schemaVersion == schemaVersion;

  @override
  int get hashCode =>
      Object.hash(participantId, balance, entryCount, schemaVersion);
}

/// The wire shape of a participant's ledger-entry list (read projection of the
/// domain `PointEntry` stream) — the response of
/// `GET /participants/{id}/entries`. A pure read projection; visibility gating
/// lives in the use-case, not this shape.
final class ParticipantEntriesDto {
  /// Creates a participant-entries DTO.
  const ParticipantEntriesDto({
    required this.participantId,
    required this.entries,
    this.schemaVersion = currentSchemaVersion,
  });

  /// Deserializes from a JSON map, defaulting [schemaVersion] for legacy
  /// payloads that predate the field.
  factory ParticipantEntriesDto.fromJson(Map<String, Object?> json) {
    final raw = json['entries']! as List<Object?>;
    return ParticipantEntriesDto(
      schemaVersion: (json['schema_version'] as int?) ?? 1,
      participantId: json['participant_id']! as String,
      entries: raw
          .map(
            (e) => PointEntryDto.fromJson(
              (e! as Map<Object?, Object?>).cast<String, Object?>(),
            ),
          )
          .toList(growable: false),
    );
  }

  /// The current schema version for this DTO.
  static const int currentSchemaVersion = 1;

  /// The participant these entries belong to (UUID string).
  final String participantId;

  /// The participant's ledger entries, in the server-defined stream order
  /// (occurred-at then id).
  final List<PointEntryDto> entries;

  /// The schema version of this payload.
  final int schemaVersion;

  /// Serializes to a JSON-encodable map.
  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'participant_id': participantId,
    'entries': [for (final e in entries) e.toJson()],
  };

  @override
  bool operator ==(Object other) =>
      other is ParticipantEntriesDto &&
      other.participantId == participantId &&
      _listEquals(other.entries, entries) &&
      other.schemaVersion == schemaVersion;

  @override
  int get hashCode =>
      Object.hash(participantId, Object.hashAll(entries), schemaVersion);

  static bool _listEquals(List<PointEntryDto> a, List<PointEntryDto> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// The wire shape echoed back after an admin posts a scored round to the ledger
/// (`POST /rounds/{id}/ledger`). Reports the round posted and the entries that
/// were appended by this post — an **empty** `entries` list means the round was
/// already fully posted (idempotent replay: nothing new appended, no
/// double-credit — Axiom 4). The command has no request body; every value here
/// is server-produced (Axioms 2/5).
final class PostRoundToLedgerResponseDto {
  /// Creates a post-round-to-ledger response DTO.
  const PostRoundToLedgerResponseDto({
    required this.roundId,
    required this.appendedEntries,
    this.schemaVersion = currentSchemaVersion,
  });

  /// Deserializes from a JSON map, defaulting [schemaVersion] for legacy
  /// payloads that predate the field.
  factory PostRoundToLedgerResponseDto.fromJson(Map<String, Object?> json) {
    final raw = json['appended_entries']! as List<Object?>;
    return PostRoundToLedgerResponseDto(
      schemaVersion: (json['schema_version'] as int?) ?? 1,
      roundId: json['round_id']! as String,
      appendedEntries: raw
          .map(
            (e) => PointEntryDto.fromJson(
              (e! as Map<Object?, Object?>).cast<String, Object?>(),
            ),
          )
          .toList(growable: false),
    );
  }

  /// The current schema version for this DTO.
  static const int currentSchemaVersion = 1;

  /// The round that was posted to the ledger (UUID string).
  final String roundId;

  /// The entries appended by this post (empty on an idempotent replay).
  final List<PointEntryDto> appendedEntries;

  /// The schema version of this payload.
  final int schemaVersion;

  /// Serializes to a JSON-encodable map.
  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'round_id': roundId,
    'appended_entries': [for (final e in appendedEntries) e.toJson()],
  };

  @override
  bool operator ==(Object other) =>
      other is PostRoundToLedgerResponseDto &&
      other.roundId == roundId &&
      _listEquals(other.appendedEntries, appendedEntries) &&
      other.schemaVersion == schemaVersion;

  @override
  int get hashCode =>
      Object.hash(roundId, Object.hashAll(appendedEntries), schemaVersion);

  static bool _listEquals(List<PointEntryDto> a, List<PointEntryDto> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
