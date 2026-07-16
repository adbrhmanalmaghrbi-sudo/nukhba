import 'package:shared/shared.dart';

/// The closed, ordered classification of what a [PointEntry] represents — the
/// *reason* points entered the append-only ledger stream (Axiom 5: the ledger
/// is the protected competitive record; every movement is explained by its
/// kind, never an unlabelled number).
///
/// Kept a closed set so a balance projection and any future statement can group
/// and reason about movements exhaustively, and so the storage/wire token can
/// never drift silently. Two kinds are defined for the Ledger phase:
///
/// * [roundScore] — the credit posted when a scored round is committed to the
///   ledger (one per `(participant, round)`; carries that round's
///   `RoundScore.totalPoints`). This is the primary movement the Scoring →
///   Ledger seam produces.
/// * [correction] — a **compensating** entry appended to adjust a previously
///   posted amount (Axiom 5: a correction is never an in-place edit or delete
///   of an existing entry — it is a new, separate entry that nets against the
///   original in the balance projection). Its amount may be negative.
///
/// The `roundScore` kind participates in the append-only dedupe key
/// `(participant_id, round_id, entry_kind)` so a re-post of the same scored
/// round can never double-credit; a `correction` legitimately coexists with the
/// original credit for the same `(participant, round)` because its kind differs.
enum EntryKind {
  /// The points credited for a participant's scored round.
  roundScore,

  /// A compensating adjustment to a previously posted amount (may be negative).
  correction;

  /// The stable wire/storage token for this kind, decoupled from the Dart
  /// identifier so a persisted value can never drift silently.
  String get wireValue => switch (this) {
    EntryKind.roundScore => 'round_score',
    EntryKind.correction => 'correction',
  };

  /// Whether an entry of this kind must carry a **non-negative** amount.
  ///
  /// A [roundScore] credit is always non-negative (points awards are
  /// non-negative — it mirrors `RoundScore.totalPoints`). A [correction] may be
  /// negative (it compensates), so it is exempt from the non-negativity rule.
  bool get requiresNonNegativeAmount => this == EntryKind.roundScore;

  /// Whether an entry of this kind participates in the append-only dedupe key
  /// so that re-posting cannot create a duplicate crediting row.
  ///
  /// Only [roundScore] is deduped on `(participant, round, kind)`: posting the
  /// same scored round twice must skip. A [correction] is intentionally
  /// append-many — an admin may append more than one compensating entry over
  /// time — so it is not deduped by this natural key (each correction carries
  /// its own distinct `source_ref`).
  bool get isDedupedPerRound => this == EntryKind.roundScore;

  /// Parses an [EntryKind] from an untrusted [raw] token (e.g. a stored row),
  /// returning a validation [AppError] when absent or unrecognized.
  static Result<EntryKind> tryParse(String? raw) {
    for (final value in EntryKind.values) {
      if (value.wireValue == raw) {
        return Result.ok(value);
      }
    }
    return Result.err(
      AppError.validation(
        'ledger.entry_kind_unknown',
        'Unknown ledger entry kind: ${raw ?? '<null>'}',
      ),
    );
  }
}
