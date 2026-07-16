import 'package:domain/src/competition/participant_id.dart';
import 'package:domain/src/ledger/point_entry.dart';
import 'package:shared/shared.dart';

/// A participant's **balance as a projection** over their append-only
/// [PointEntry] stream — never a directly mutated number (Axiom 5; Database ADR:
/// "balance is a projection").
///
/// This is the domain-side embodiment of the ledger discipline: the balance is
/// *derived* by summing every entry's signed amount, so it is always consistent
/// with the immutable stream and a correction (a compensating entry) naturally
/// nets into it without any entry ever being edited. It carries no mutable
/// total-of-truth — there is no setter, only [project], the pure reduction.
///
/// Pure and immutable; value-comparable by `(participantId, balance,
/// entryCount)`.
final class LedgerBalance {
  const LedgerBalance._({
    required this.participantId,
    required this.balance,
    required this.entryCount,
  });

  /// Projects the balance for [participantId] by summing [entries] (the
  /// participant's ledger stream).
  ///
  /// Total and deterministic: the same stream always yields the same balance.
  /// It is an [ErrorKind.invariant] failure if any entry in [entries] does not
  /// belong to [participantId] — a mixed stream would silently mis-project one
  /// participant's balance from another's movements (a competitive-record
  /// corruption, Axiom 5), so it is refused rather than summed blindly. An
  /// empty stream projects a zero balance (a participant who has never been
  /// credited legitimately has zero, distinct from "unknown").
  static Result<LedgerBalance> project({
    required ParticipantId participantId,
    required List<PointEntry> entries,
  }) {
    var total = 0;
    for (final entry in entries) {
      if (entry.participantId != participantId) {
        return Result.err(
          AppError.invariant(
            'ledger.balance_foreign_entry',
            'An entry for participant ${entry.participantId.value} cannot '
                'contribute to participant ${participantId.value}\'s balance',
          ),
        );
      }
      total += entry.amount;
    }
    return Result.ok(
      LedgerBalance._(
        participantId: participantId,
        balance: total,
        entryCount: entries.length,
      ),
    );
  }

  /// The participant this balance is projected for.
  final ParticipantId participantId;

  /// The signed sum of every entry's amount in the participant's stream.
  final int balance;

  /// How many entries contributed to the projection (audit/traceability — a
  /// balance is always explainable by this many immutable movements).
  final int entryCount;

  @override
  bool operator ==(Object other) =>
      other is LedgerBalance &&
      other.participantId == participantId &&
      other.balance == balance &&
      other.entryCount == entryCount;

  @override
  int get hashCode => Object.hash(participantId, balance, entryCount);

  @override
  String toString() =>
      'LedgerBalance(participant: ${participantId.value}, '
      'balance: $balance, entries: $entryCount)';
}
