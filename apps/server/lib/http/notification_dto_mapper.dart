import 'package:contracts/contracts.dart';
import 'package:domain/domain.dart';

/// Projects the Notifications (Tier-3) domain read values onto their versioned
/// wire shapes (API ADR §4), in one place, so every notification read response
/// shapes an entity identically and no route hand-rolls the DTO fields.
///
/// Notifications is a Tier-3 peripheral aggregate (Database ADR §3),
/// recipient-scoped (decision #4) and NEVER a second points source (Axiom 5):
/// none of these shapes carry a points-write field or an open-graph edge. The
/// notification [kind] crosses the wire as its stable [NotificationKind.wireValue]
/// token (the copy/glyph is a client presentation concern), mirroring how
/// `ReactionDto.emoji` / `GroupMembershipDto.role` carry tokens, not
/// presentation. The kind-specific subject references (round/group/actor) are
/// projected from the domain [NotificationSubject]; the DTO omits the null ones
/// from JSON so the payload stays minimal per kind.

/// Projects one domain [Notification] onto the wire [NotificationDto].
///
/// The [Notification.kind] crosses the wire as its stable `wireValue` token. The
/// read state is derived from the domain aggregate ([Notification.isRead] +
/// [Notification.readAt]); an unread notification omits `read_at`. The
/// kind-discriminated subject references travel as their id strings (null for a
/// kind that does not carry them). Instants are emitted as ISO-8601 UTC strings
/// (the domain enforces UTC). Carries no points field (Axiom 5) and no
/// open-graph edge (ADR-001).
NotificationDto notificationToDto(Notification notification) {
  final subject = notification.subject;
  return NotificationDto(
    id: notification.id.value,
    recipientId: notification.recipientId.value,
    kind: notification.kind.wireValue,
    read: notification.isRead,
    // Always UTC (Notification.create/markRead enforce isUtc); ISO-8601.
    createdAt: notification.createdAt.toUtc().toIso8601String(),
    readAt: notification.readAt?.toUtc().toIso8601String(),
    roundId: subject.roundId?.value,
    groupId: subject.groupId?.value,
    actorUserId: subject.actorUserId?.value,
  );
}

/// Shapes the response of `GET /notifications` — the caller's own notification
/// list in the server-defined order (createdAt descending — newest first) plus
/// their whole-inbox [unreadCount] (not just the returned page).
///
/// [recipientId] is the verified principal's user id (the id every returned
/// notification is scoped to — decision #4). An empty [notifications] list is a
/// legitimate result (a recipient with no notifications), never an error.
Map<String, Object?> notificationListJson(
  String recipientId,
  List<Notification> notifications,
  int unreadCount,
) {
  return NotificationListDto(
    recipientId: recipientId,
    notifications: [for (final n in notifications) notificationToDto(n)],
    unreadCount: unreadCount,
  ).toJson();
}
