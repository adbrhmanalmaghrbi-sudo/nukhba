import 'package:application/src/notification/create_notification.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// Server-side trigger command: notify each participant of a round that was
/// scored (Notifications decision #1 — `round_scored`, the single most-awaited
/// moment in the predict-once loop).
///
/// **NOT client-callable** — invoked by the backend from the `ScoreRound`
/// trigger edge (composition), once per participant of the just-scored round,
/// AFTER the `locked → scored` transition. The recipient is the participant's
/// `User`; the subject references the scored [roundId] (via
/// [NotificationSubject.roundScored]), so the dedupe ref is `round:<roundId>` —
/// re-scoring the same round never notifies a participant twice (decision #3
/// idempotency).
///
/// **Tier-3 (decision #4; ADR 0007 §2.4):** delegates to [CreateNotification],
/// whose failure is a typed `Result.err` the trigger site treats as
/// best-effort — it never blocks or fails `ScoreRound` (a Tier-1 operation).
///
/// Returns `Ok(true)` when a new notification was created, `Ok(false)` on an
/// idempotent replay.
final class NotifyRoundScored {
  /// Creates the use-case over its single collaborator.
  const NotifyRoundScored({required CreateNotification create})
    : _create = create;

  final CreateNotification _create;

  /// Notifies [recipientId] that [roundId] (which they participate in) was
  /// scored.
  Future<Result<bool>> call({
    required UserId recipientId,
    required RoundId roundId,
  }) {
    return _create(
      recipientId: recipientId,
      kind: NotificationKind.roundScored,
      subject: NotificationSubject.roundScored(roundId: roundId),
    );
  }
}
