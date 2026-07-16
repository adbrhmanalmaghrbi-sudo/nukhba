import 'package:application/src/notification/create_notification.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// Server-side trigger command: notify a round's participant that another member
/// reacted to their round-result (Notifications decision #1 —
/// `reaction_received`, "someone reacted to your prediction").
///
/// **NOT client-callable** — invoked by the backend from the `ReactToRound`
/// trigger edge (composition) AFTER a reaction is recorded. The recipient is the
/// round's participant `User` ([recipientId]); the actor is the reactor
/// ([actorUserId]). A member reacting to their OWN round-result notifies no one
/// — the trigger site MUST NOT invoke this command when `recipientId ==
/// actorUserId`; this command enforces that as a guard (a self-reaction is a
/// silent `Ok(false)` no-op rather than a self-notification).
///
/// The subject references the [groupId] + [roundId] + reacting [actorUserId]
/// (via [NotificationSubject.reactionReceived]), so the dedupe ref is
/// `reaction:<groupId>:<roundId>:<actorUserId>` — the same reactor's repeated
/// reactions to the same round-result in the same group never notify the
/// recipient twice (decision #3 idempotency; a reactor swapping emoji is one
/// event).
///
/// **Tier-3 (decision #4; ADR 0007 §2.4):** delegates to [CreateNotification],
/// whose failure is a typed `Result.err` the trigger site treats as
/// best-effort — it never blocks or fails `ReactToRound` (a Tier-1 operation).
///
/// Returns `Ok(true)` when a new notification was created, `Ok(false)` on an
/// idempotent replay or a suppressed self-reaction.
final class NotifyReactionReceived {
  /// Creates the use-case over its single collaborator.
  const NotifyReactionReceived({required CreateNotification create})
    : _create = create;

  final CreateNotification _create;

  /// Notifies [recipientId] (the round's participant) that [actorUserId] reacted
  /// to [roundId] within [groupId].
  Future<Result<bool>> call({
    required UserId recipientId,
    required GroupId groupId,
    required RoundId roundId,
    required UserId actorUserId,
  }) async {
    // A member reacting to their own round-result notifies no one (decision #1).
    if (recipientId == actorUserId) {
      return const Result.ok(false);
    }
    return _create(
      recipientId: recipientId,
      kind: NotificationKind.reactionReceived,
      subject: NotificationSubject.reactionReceived(
        groupId: groupId,
        roundId: roundId,
        actorUserId: actorUserId,
      ),
    );
  }
}
