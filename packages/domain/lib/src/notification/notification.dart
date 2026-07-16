import 'package:domain/src/identity/user_id.dart';
import 'package:domain/src/notification/notification_id.dart';
import 'package:domain/src/notification/notification_kind.dart';
import 'package:domain/src/notification/notification_subject.dart';
import 'package:shared/shared.dart';

/// A single in-app notification addressed to exactly one recipient — the ONE
/// new stored Tier-3 surface this phase introduces (Notifications decision #3:
/// genuinely stored, per-user, MUTABLE read-state, unlike Social's pure
/// projection feed).
///
/// A [Notification] is **recipient-scoped** (decision #4: a notification belongs
/// to one [recipientId] `User`; the read/list/mark gate is "caller ==
/// recipient", NOT group-membership). Its [kind] is one of the closed set
/// (decision #1) and its [subject] carries the kind-specific references a client
/// renders/deep-links (and the deterministic dedupe ref that makes creation
/// idempotent). The recipient is bound server-side from the ratified trigger,
/// never a request body (Security ADR §2).
///
/// It carries **NO points field** (Axiom 5 — Notifications is never a second
/// points source) and **NO open-graph edge / free text** (decision #1;
/// ADR-001). The only mutable state is the read flag ([readAt]): unread when
/// null, read when set. State changes produce new values (see [markRead]);
/// marking an already-read notification is idempotent (returns an equal value,
/// preserving the original read timestamp), so a retried mark-read converges.
/// Value-comparable.
final class Notification {
  const Notification._({
    required this.id,
    required this.recipientId,
    required this.kind,
    required this.subject,
    required this.createdAt,
    required this.readAt,
  });

  /// Rehydrates a [Notification] from already-trusted stored fields (used by the
  /// infrastructure mapper). Performs no validation beyond typing — callers
  /// creating a *new* notification from a trigger must use [create].
  const Notification.fromStored({
    required this.id,
    required this.recipientId,
    required this.kind,
    required this.subject,
    required this.createdAt,
    required this.readAt,
  });

  /// Creates a new, **unread** notification from validated inputs.
  ///
  /// [id] is already a validated value object (generated server-side). [subject]
  /// must belong to the same [kind] as this notification (a `roundScored`
  /// notification must carry a `roundScored` subject) — a mismatch is a caller
  /// bug caught here as a typed validation error rather than persisted. The
  /// notification starts unread ([readAt] null). [createdAt] must be a UTC
  /// instant (callers normalize) so the newest-first ordering is unambiguous.
  static Result<Notification> create({
    required NotificationId id,
    required UserId recipientId,
    required NotificationKind kind,
    required NotificationSubject subject,
    required DateTime createdAt,
  }) {
    if (subject.kind != kind) {
      return Result.err(
        AppError.validation(
          'notification.subject_kind_mismatch',
          'Subject kind ${subject.kind.wireValue} does not match '
              'notification kind ${kind.wireValue}',
        ),
      );
    }
    if (!createdAt.isUtc) {
      return const Result.err(
        AppError.validation(
          'notification.created_at_not_utc',
          'createdAt must be provided in UTC',
        ),
      );
    }
    return Result.ok(
      Notification._(
        id: id,
        recipientId: recipientId,
        kind: kind,
        subject: subject,
        createdAt: createdAt,
        readAt: null,
      ),
    );
  }

  /// The notification identity.
  final NotificationId id;

  /// The single recipient — the only user who may read/mark this notification
  /// (decision #4). Bound from the ratified trigger, never a request body.
  final UserId recipientId;

  /// The kind (a member of the closed set — decision #1).
  final NotificationKind kind;

  /// The kind-specific reference payload (round/group/actor + the dedupe ref).
  final NotificationSubject subject;

  /// When the notification was created (UTC) — the newest-first ordering key.
  final DateTime createdAt;

  /// When the recipient marked this read (UTC), or null while unread.
  final DateTime? readAt;

  /// Whether the recipient has read this notification.
  bool get isRead => readAt != null;

  /// Returns a copy marked read at [nowUtc].
  ///
  /// **Idempotent:** if the notification is already read, the SAME value is
  /// returned (the original [readAt] is preserved, never reset), so a retried
  /// mark-read converges. Authority (the caller must be the [recipientId]) is
  /// enforced in the use-case, not here (an aggregate reasons only about
  /// itself). [nowUtc] must be UTC.
  Result<Notification> markRead(DateTime nowUtc) {
    if (isRead) {
      return Result.ok(this);
    }
    if (!nowUtc.isUtc) {
      return const Result.err(
        AppError.validation(
          'notification.read_at_not_utc',
          'readAt must be provided in UTC',
        ),
      );
    }
    return Result.ok(
      Notification._(
        id: id,
        recipientId: recipientId,
        kind: kind,
        subject: subject,
        createdAt: createdAt,
        readAt: nowUtc,
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Notification &&
      other.id == id &&
      other.recipientId == recipientId &&
      other.kind == kind &&
      other.subject == subject &&
      other.createdAt == createdAt &&
      other.readAt == readAt;

  @override
  int get hashCode =>
      Object.hash(id, recipientId, kind, subject, createdAt, readAt);

  @override
  String toString() =>
      'Notification(${id.value}, to: ${recipientId.value}, '
      '${kind.wireValue}, ${isRead ? 'read' : 'unread'})';
}
