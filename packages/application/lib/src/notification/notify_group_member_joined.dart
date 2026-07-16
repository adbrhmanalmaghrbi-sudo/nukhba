import 'package:application/src/notification/create_notification.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// Server-side trigger command: notify a group's **owner** that a new member
/// joined (Notifications decision #1 — `group_member_joined`, kept owner-only in
/// v1 to avoid an N² fan-out; only the group owner is told someone joined via
/// their invite).
///
/// **NOT client-callable** — invoked by the backend from the `JoinGroupByInvite`
/// trigger edge (composition) AFTER a successful, non-idempotent join (a member
/// re-confirming an existing membership must NOT re-notify — the caller passes
/// this only on a genuinely new join). The recipient is the group [ownerId]; the
/// subject references the [groupId] + the joining [actorUserId] (via
/// [NotificationSubject.groupMemberJoined]), so the dedupe ref is
/// `group_join:<groupId>:<actorUserId>` — the same person joining the same group
/// never notifies the owner twice (decision #3 idempotency).
///
/// The self-join case (an owner is always already a member, and a joiner is
/// never the owner of a group they are joining for the first time) means the
/// recipient (owner) and actor (joiner) are distinct in practice; this command
/// makes no assumption and simply records what the trigger site resolved.
///
/// **Tier-3 (decision #4; ADR 0007 §2.4):** delegates to [CreateNotification],
/// whose failure is a typed `Result.err` the trigger site treats as
/// best-effort — it never blocks or fails `JoinGroupByInvite` (a Tier-1
/// operation).
///
/// Returns `Ok(true)` when a new notification was created, `Ok(false)` on an
/// idempotent replay.
final class NotifyGroupMemberJoined {
  /// Creates the use-case over its single collaborator.
  const NotifyGroupMemberJoined({required CreateNotification create})
    : _create = create;

  final CreateNotification _create;

  /// Notifies the group [ownerId] that [actorUserId] joined [groupId].
  Future<Result<bool>> call({
    required UserId ownerId,
    required GroupId groupId,
    required UserId actorUserId,
  }) {
    return _create(
      recipientId: ownerId,
      kind: NotificationKind.groupMemberJoined,
      subject: NotificationSubject.groupMemberJoined(
        groupId: groupId,
        actorUserId: actorUserId,
      ),
    );
  }
}
