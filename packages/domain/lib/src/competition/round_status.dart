import 'package:shared/shared.dart';

/// The lifecycle state of a [Round] (Database ADR, Section 3 & Section: domain
/// invariants — "the round's `ruleset_snapshot` column is write-once; a trigger
/// rejects any UPDATE once the round status has left the open state").
///
/// The state machine is deliberately linear and forward-only:
/// ```
/// open ──lock──▶ locked ──score──▶ scored
/// ```
/// * [open] — accepting predictions; the ruleset snapshot has been frozen at
///   open time and is immutable thereafter.
/// * [locked] — the prediction deadline has passed; no new predictions, awaiting
///   results/scoring (Scoring is a later phase).
/// * [scored] — results applied and points awarded (by the later Scoring/Ledger
///   phases); terminal.
///
/// The transition policy is defined once, here, so every use-case reasons about
/// round lifecycle identically. A backward or skipping transition is an
/// invariant violation, never silently allowed.
enum RoundStatus {
  /// Accepting predictions; ruleset frozen.
  open,

  /// Deadline passed; predictions closed, awaiting scoring.
  locked,

  /// Results applied and points awarded; terminal.
  scored;

  /// The stable wire/storage token for this status.
  String get wireValue => switch (this) {
    RoundStatus.open => 'open',
    RoundStatus.locked => 'locked',
    RoundStatus.scored => 'scored',
  };

  /// Whether the round is currently accepting predictions. Only [open] rounds
  /// are mutable in the ways that matter (predictions in, fixtures linkable);
  /// once left [open] the ruleset snapshot is frozen forever.
  bool get isOpen => this == RoundStatus.open;

  /// Whether a transition from this status to [next] is permitted by the linear
  /// lifecycle. Defined once so no use-case re-derives the machine.
  ///
  /// Permitted edges: `open → locked`, `locked → scored`. Everything else
  /// (including no-op self-transitions and any backward move) is rejected.
  bool canTransitionTo(RoundStatus next) => switch (this) {
    RoundStatus.open => next == RoundStatus.locked,
    RoundStatus.locked => next == RoundStatus.scored,
    RoundStatus.scored => false,
  };

  /// Parses a [RoundStatus] from an untrusted [raw] token, returning a
  /// validation [AppError] when it is absent or unrecognized.
  static Result<RoundStatus> tryParse(String? raw) {
    for (final value in RoundStatus.values) {
      if (value.wireValue == raw) {
        return Result.ok(value);
      }
    }
    return Result.err(
      AppError.validation(
        'competition.round_status_unknown',
        'Unknown round status: ${raw ?? '<null>'}',
      ),
    );
  }
}
