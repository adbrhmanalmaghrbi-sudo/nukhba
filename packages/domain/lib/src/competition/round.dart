import 'package:domain/src/competition/round_id.dart';
import 'package:domain/src/competition/round_status.dart';
import 'package:domain/src/competition/ruleset_snapshot.dart';
import 'package:domain/src/competition/season_id.dart';
import 'package:shared/shared.dart';

/// A round within a [CompetitionSeason] — the unit users predict, and the
/// carrier of the frozen ruleset (Database ADR, Section 3: a round belongs to
/// exactly one season and carries the write-once `ruleset_snapshot`).
///
/// The two founding invariants of the whole Competition phase live *in this
/// entity* (the application is the first line of defence; the DB trigger is the
/// backstop — Axiom 6):
///
/// 1. **Ruleset freeze** — the [ruleset] is captured at [open] time and is
///    write-once: it can never change once the round has left the [RoundStatus.open]
///    state. This is why changing the active ruleset later can never rewrite a
///    historical round (Next-Task brief). There is deliberately no API on this
///    entity to replace a snapshot; the field is set once at construction.
/// 2. **Linear lifecycle** — status advances only `open → locked → scored`
///    ([RoundStatus.canTransitionTo]); backward or skipping moves are rejected.
///
/// Pure and immutable; state changes produce new values.
final class Round {
  const Round._({
    required this.id,
    required this.seasonId,
    required this.sequence,
    required this.predictionDeadline,
    required this.status,
    required this.ruleset,
  });

  /// Rehydrates a round from already-trusted stored fields (infrastructure
  /// mapper). No validation beyond typing; the stored snapshot is trusted to be
  /// the one frozen at open time.
  const Round.fromStored({
    required this.id,
    required this.seasonId,
    required this.sequence,
    required this.predictionDeadline,
    required this.status,
    required this.ruleset,
  });

  /// Opens a brand-new round.
  ///
  /// A round is *born [RoundStatus.open]* with its ruleset already frozen —
  /// there is no "draft" state in which the snapshot could be edited, which is
  /// what makes the freeze total. Validates:
  /// * [sequence] is a positive, 1-based ordinal within its season;
  /// * [predictionDeadline] is a UTC instant (callers must normalize) — stored
  ///   in UTC so deadline comparisons in later phases are unambiguous.
  ///
  /// The [ruleset] is an already-validated [RulesetSnapshot] (built via
  /// [RulesetSnapshot.create]); capturing it here is the freeze.
  static Result<Round> open({
    required RoundId id,
    required SeasonId seasonId,
    required int sequence,
    required DateTime predictionDeadline,
    required RulesetSnapshot ruleset,
  }) {
    if (sequence < 1) {
      return const Result.err(
        AppError.validation(
          'competition.round_sequence_invalid',
          'Round sequence must be a positive 1-based ordinal',
        ),
      );
    }
    if (!predictionDeadline.isUtc) {
      return const Result.err(
        AppError.validation(
          'competition.round_deadline_not_utc',
          'Prediction deadline must be provided in UTC',
        ),
      );
    }
    return Result.ok(
      Round._(
        id: id,
        seasonId: seasonId,
        sequence: sequence,
        predictionDeadline: predictionDeadline,
        status: RoundStatus.open,
        ruleset: ruleset,
      ),
    );
  }

  /// The round identity.
  final RoundId id;

  /// The owning season. A round belongs to exactly one season (Database ADR,
  /// Section 3).
  final SeasonId seasonId;

  /// The 1-based ordinal of this round within its season (round 1, 2, 3, …).
  /// Unique per season (enforced structurally in the schema).
  final int sequence;

  /// The instant after which predictions are no longer accepted (UTC). The
  /// Prediction phase enforces immutability-after-deadline against this value.
  final DateTime predictionDeadline;

  /// The current lifecycle state.
  final RoundStatus status;

  /// The frozen ruleset governing this round. Write-once: captured at [open] and
  /// never mutated (Database ADR, Section 3).
  final RulesetSnapshot ruleset;

  /// Advances the round to [next], enforcing the linear lifecycle.
  ///
  /// Returns an [ErrorKind.invariant] error for any illegal transition (backward,
  /// skipping, or a no-op self-transition) — round lifecycle is a business rule,
  /// not malformed input. The frozen [ruleset] is carried through unchanged: a
  /// transition never touches the snapshot, which is precisely the freeze
  /// guarantee.
  Result<Round> transitionTo(RoundStatus next) {
    if (!status.canTransitionTo(next)) {
      return Result.err(
        AppError.invariant(
          'competition.round_illegal_transition',
          'Cannot move round from ${status.wireValue} to ${next.wireValue}',
        ),
      );
    }
    return Result.ok(
      Round._(
        id: id,
        seasonId: seasonId,
        sequence: sequence,
        predictionDeadline: predictionDeadline,
        status: next,
        ruleset: ruleset,
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Round &&
      other.id == id &&
      other.seasonId == seasonId &&
      other.sequence == sequence &&
      other.predictionDeadline == predictionDeadline &&
      other.status == status &&
      other.ruleset == ruleset;

  @override
  int get hashCode =>
      Object.hash(id, seasonId, sequence, predictionDeadline, status, ruleset);

  @override
  String toString() =>
      'Round(${id.value}, season: ${seasonId.value}, #$sequence, '
      '${status.wireValue})';
}
