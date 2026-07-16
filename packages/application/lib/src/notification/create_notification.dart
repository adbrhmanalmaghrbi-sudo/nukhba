import 'package:application/src/common/clock.dart';
import 'package:application/src/common/id_generator.dart';
import 'package:application/src/notification/ports/notification_repository.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// Server-side creation facade for a single [Notification] — the ONE idempotent
/// create path all three ratified trigger commands (`NotifyRoundScored`,
/// `NotifyGroupMemberJoined`, `NotifyReactionReceived`) delegate to, so the
/// trigger sites depend on one thing (Notifications design-anchors §2).
///
/// This is **NOT client-callable** (decision #4: creation is server-triggered
/// only). It carries no `Authorization.requireRole(user)` self-gate — it is
/// invoked by the backend AFTER a ratified event with an already-resolved
/// recipient + subject, generates the id server-side ([IdGenerator]), stamps
/// `createdAt` from the injected [Clock] (UTC), and performs an idempotent
/// [NotificationRepository.createIfAbsent] keyed on the deterministic
/// `(recipientId, kind, subjectRef)` dedupe ref (decision #3, mirror of the
/// Ledger dedupe discipline) — a replayed trigger is a no-op skip, never a
/// second row.
///
/// **Tier-3 degradation (decision #4; ADR 0007 §2.4):** the returned
/// [Result.err] on failure is confined to the notification call; the trigger
/// site (ScoreRound / JoinGroup / ReactToRound) treats notification creation as
/// best-effort and MUST NOT propagate a failure into its Tier-1 result. This
/// use-case therefore neither throws nor blocks; it just reports.
///
/// Returns `Ok(true)` when a NEW notification was created, `Ok(false)` when an
/// identical one already existed (an idempotent replay).
final class CreateNotification {
  /// Creates the use-case over its collaborators.
  const CreateNotification({
    required NotificationRepository notifications,
    required IdGenerator idGenerator,
    required Clock clock,
  }) : _notifications = notifications,
       _idGenerator = idGenerator,
       _clock = clock;

  final NotificationRepository _notifications;
  final IdGenerator _idGenerator;
  final Clock _clock;

  /// Creates a notification for [recipientId] of [kind] with [subject],
  /// idempotently. The [subject]'s kind must match [kind] (enforced by
  /// [Notification.create]); a mismatch is a caller bug surfaced as a typed
  /// validation error, never persisted.
  Future<Result<bool>> call({
    required UserId recipientId,
    required NotificationKind kind,
    required NotificationSubject subject,
  }) async {
    final idResult = NotificationId.tryParse(_idGenerator.newUuid());
    if (idResult is Err<NotificationId>) {
      return Result.err(idResult.error);
    }
    final id = (idResult as Ok<NotificationId>).value;

    final built = Notification.create(
      id: id,
      recipientId: recipientId,
      kind: kind,
      subject: subject,
      createdAt: _clock.nowUtc(),
    );
    if (built is Err<Notification>) {
      return Result.err(built.error);
    }
    final notification = (built as Ok<Notification>).value;

    return _notifications.createIfAbsent(notification);
  }
}
