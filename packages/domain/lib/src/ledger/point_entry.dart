import 'package:domain/src/competition/participant_id.dart';
import 'package:domain/src/competition/round_id.dart';
import 'package:domain/src/ledger/entry_kind.dart';
import 'package:domain/src/ledger/point_entry_id.dart';
import 'package:shared/shared.dart';

/// A single, **immutable, append-only** movement of points in the Ledger —
/// the protected competitive record made physical (Axiom 5: points are a
/// virtual-value instrument; the ledger is the asset to protect, so entries are
/// only ever appended, never edited or deleted; a correction is a separate
/// compensating entry).
///
/// An entry names the [participantId] and [roundId] it derives from **by id
/// only** (Database ADR: reference by id, not by embedding the aggregate) and
/// carries no group reference (Axiom 4: the one score, ranked everywhere — the
/// ledger reflects it without a group binding). Its [amount] is the signed
/// point movement (a [EntryKind.roundScore] credit is non-negative and mirrors
/// the scored round's `totalPoints`; a [EntryKind.correction] may be negative).
///
/// There is deliberately **no mutation API** on this class — no copy-with, no
/// setter, no `transitionTo`. Once constructed, an entry is final. Correcting a
/// past mistake means *appending a new* [EntryKind.correction] entry, never
/// changing an existing one (Axiom 5). This is enforced structurally here (the
/// type offers no way to change a field) and physically by the migration
/// (revoked UPDATE/DELETE + an immutability trigger — Axiom 6, the backstop).
///
/// [amount] is server-computed only (Axiom 2: the client never submits or
/// computes a point amount — the amount is copied from the frozen
/// `RoundScore.totalPoints`, or set by an admin correction command).
///
/// Pure and immutable; value-comparable by all fields.
final class PointEntry {
  const PointEntry._({
    required this.id,
    required this.participantId,
    required this.roundId,
    required this.kind,
    required this.amount,
    required this.sourceRef,
    required this.occurredAt,
  });

  /// Rehydrates an entry from already-trusted stored fields (infrastructure
  /// mapper). The stored values were validated by [create] (and the DB check
  /// constraints, Axiom 6) before they were ever written, so no re-validation
  /// is performed here.
  const PointEntry.fromStored({
    required this.id,
    required this.participantId,
    required this.roundId,
    required this.kind,
    required this.amount,
    required this.sourceRef,
    required this.occurredAt,
  });

  /// Creates a validated point entry from server-side inputs.
  ///
  /// Enforced invariants (kept total — no exception escapes a command path):
  /// * [occurredAt] must be UTC (`DateTime.isUtc`), so ledger ordering and
  ///   audit are unambiguous across zones.
  /// * a [kind] that [EntryKind.requiresNonNegativeAmount] (a
  ///   [EntryKind.roundScore] credit) must have a non-negative [amount] — a
  ///   negative credit would corrupt the competitive record. A
  ///   [EntryKind.correction] may be negative (it compensates).
  /// * [sourceRef] must be non-empty — every entry records its provenance (the
  ///   originating `round_score`, or the correction's justification handle) so
  ///   the append-only stream is fully auditable and the dedupe key is
  ///   meaningful.
  static Result<PointEntry> create({
    required PointEntryId id,
    required ParticipantId participantId,
    required RoundId roundId,
    required EntryKind kind,
    required int amount,
    required String sourceRef,
    required DateTime occurredAt,
  }) {
    if (!occurredAt.isUtc) {
      return const Result.err(
        AppError.validation(
          'ledger.entry_occurred_at_not_utc',
          'occurredAt must be provided in UTC',
        ),
      );
    }
    if (sourceRef.isEmpty) {
      return const Result.err(
        AppError.validation(
          'ledger.entry_source_ref_empty',
          'A point entry must carry a non-empty source reference',
        ),
      );
    }
    if (kind.requiresNonNegativeAmount && amount < 0) {
      return Result.err(
        AppError.validation(
          'ledger.entry_amount_negative',
          'A ${kind.wireValue} entry amount must not be negative',
        ),
      );
    }
    return Result.ok(
      PointEntry._(
        id: id,
        participantId: participantId,
        roundId: roundId,
        kind: kind,
        amount: amount,
        sourceRef: sourceRef,
        occurredAt: occurredAt,
      ),
    );
  }

  /// The entry's own stable identity.
  final PointEntryId id;

  /// The participant this movement belongs to (by id — the balance is projected
  /// per participant).
  final ParticipantId participantId;

  /// The round this movement derives from (by id). Combined with
  /// [participantId] and [kind] this is the append-only dedupe key for a
  /// [EntryKind.roundScore] credit (Axiom 4: no double-credit on re-post).
  final RoundId roundId;

  /// Why the points moved (the closed [EntryKind] classification).
  final EntryKind kind;

  /// The signed point movement. A [EntryKind.roundScore] credit is
  /// non-negative (mirrors the scored round's `totalPoints`); a
  /// [EntryKind.correction] may be negative. Server-computed only (Axiom 2).
  final int amount;

  /// The provenance handle recording where this entry came from — the
  /// originating scored round (for a credit) or the correction's justification
  /// reference (for a compensating entry). Never empty; server-set.
  final String sourceRef;

  /// When the movement occurred (UTC), for stream ordering and audit.
  final DateTime occurredAt;

  @override
  bool operator ==(Object other) =>
      other is PointEntry &&
      other.id == id &&
      other.participantId == participantId &&
      other.roundId == roundId &&
      other.kind == kind &&
      other.amount == amount &&
      other.sourceRef == sourceRef &&
      other.occurredAt == occurredAt;

  @override
  int get hashCode => Object.hash(
    id,
    participantId,
    roundId,
    kind,
    amount,
    sourceRef,
    occurredAt,
  );

  @override
  String toString() =>
      'PointEntry(${id.value}, participant: ${participantId.value}, '
      'round: ${roundId.value}, ${kind.wireValue}, amount: $amount)';
}
