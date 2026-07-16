import 'package:contracts/contracts.dart';
import 'package:domain/domain.dart';

/// Projects the domain Ledger read values onto their versioned wire shapes
/// (API ADR §4), in one place, so every ledger read/command response shapes an
/// entry identically.
///
/// Integrity boundary (Axioms 2/5): a ledger movement is a **server-produced
/// read value** — the amount, kind token, provenance, and instant are echoed
/// exactly as the domain produced/stored them; nothing here is client-writable
/// and there is no inverse (the client never sends an entry or a balance). The
/// entry [kind] crosses the wire as its stable [EntryKind.wireValue] token
/// (`round_score` / `correction`), never a Dart enum name, so a persisted or
/// transmitted value can never drift silently. The [occurredAt] instant is
/// emitted as an ISO-8601 UTC string. Names a participant and round by id only
/// (Axiom 4: no group reference).

/// Projects one immutable [PointEntry] onto the wire [PointEntryDto].
PointEntryDto pointEntryToDto(PointEntry entry) {
  return PointEntryDto(
    id: entry.id.value,
    participantId: entry.participantId.value,
    roundId: entry.roundId.value,
    kind: entry.kind.wireValue,
    amount: entry.amount,
    sourceRef: entry.sourceRef,
    // Always UTC (the domain PointEntry.create enforces isUtc); ISO-8601.
    occurredAt: entry.occurredAt.toUtc().toIso8601String(),
  );
}

/// Shapes the response of `POST /rounds/{id}/ledger` — the round posted plus the
/// entries this post actually appended. An **empty** list means the round was
/// already fully posted (idempotent replay: nothing new, no double-credit —
/// Axiom 4). [roundId] is the requested round every appended entry shares.
Map<String, Object?> postRoundToLedgerResponseJson(
  String roundId,
  List<PointEntry> appendedEntries,
) {
  return PostRoundToLedgerResponseDto(
    roundId: roundId,
    appendedEntries: [
      for (final entry in appendedEntries) pointEntryToDto(entry),
    ],
  ).toJson();
}

/// Shapes the response of `GET /participants/{id}/balance` — the participant's
/// projected balance over their append-only stream (Axiom 5: a projection,
/// never a stored mutable number). [participantId] is the requested id (the same
/// the balance is projected for).
Map<String, Object?> balanceJson(String participantId, LedgerBalance balance) {
  return BalanceDto(
    participantId: participantId,
    balance: balance.balance,
    entryCount: balance.entryCount,
  ).toJson();
}

/// Shapes the response of `GET /participants/{id}/entries` — the participant's
/// append-only entry stream in the server-defined order (occurred-at then id).
/// [participantId] is the requested id; every entry belongs to it (the use-case
/// gated the read to a self-owned participant).
Map<String, Object?> participantEntriesJson(
  String participantId,
  List<PointEntry> entries,
) {
  return ParticipantEntriesDto(
    participantId: participantId,
    entries: [for (final entry in entries) pointEntryToDto(entry)],
  ).toJson();
}
