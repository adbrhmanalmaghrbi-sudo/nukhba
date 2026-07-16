import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// Persistence port for the Notifications surface — the ONE new stored Tier-3
/// aggregate (Notifications decision #3: genuinely stored, per-user, MUTABLE
/// read-state; Application ADR §9: use-cases depend on repository interfaces,
/// Infrastructure implements them).
///
/// Backed by `PostgresNotificationRepository`. The interface speaks in the
/// domain [Notification] aggregate and typed ids, never rows or SQL, so
/// use-cases stay pure and testable against an in-memory fake.
///
/// General contract for every method (Application ADR §2):
/// * MUST NOT throw — every outcome is a typed [Result].
/// * MUST map infrastructure failures to [ErrorKind.transient].
/// * MUST map a storage-only uniqueness conflict on the dedupe key
///   `(recipientId, kind, subjectRef)` to [ErrorKind.invariant]
///   `notification.duplicate` so [createIfAbsent] converges on it as a skip
///   (a replayed trigger never appends a second identical notification).
///
/// **Tier-3 degradation (decision #4; ADR 0007 §2.4):** a failure here is a
/// typed `Result.err` confined to the notification use-case that called it; it
/// never propagates into a Tier-1 core operation (prediction/scoring/ledger/
/// leaderboard), which do not depend on this port.
abstract interface class NotificationRepository {
  /// Persists [notification] **idempotently** on the dedupe key
  /// `(recipientId, kind, subjectRef)` — where `subjectRef` is the
  /// deterministic [NotificationSubject.dedupeRef] (decision #3, mirror of the
  /// Ledger dedupe discipline).
  ///
  /// Returns `Ok(true)` when a NEW row was inserted, `Ok(false)` when an
  /// identical notification already existed (a replayed trigger — a no-op skip,
  /// never a second row and never an error). A racing duplicate that the DB
  /// rejects surfaces as [ErrorKind.invariant] `notification.duplicate`, which
  /// the adapter converts to `Ok(false)` so a concurrent replay still converges.
  Future<Result<bool>> createIfAbsent(Notification notification);

  /// Lists [recipientId]'s notifications, newest-first (createdAt descending,
  /// then id descending as a stable tiebreak), truncated to [limit] rows.
  ///
  /// Recipient-scoped: only rows whose `recipient_id` equals [recipientId] are
  /// returned (decision #4). An empty list is a legitimate result (a recipient
  /// with no notifications). [limit] is already clamped by the use-case.
  Future<Result<List<Notification>>> listForRecipient(
    UserId recipientId, {
    required int limit,
  });

  /// Finds the notification [id] **only if it belongs to** [recipientId], or
  /// `Ok(null)` when there is no such notification visible to that recipient.
  ///
  /// Recipient-scoped (decision #4): a notification owned by someone else, or a
  /// non-existent id, both resolve to `Ok(null)` — the caller (the use-case)
  /// then reports `notification.not_found`, so the read is never an existence
  /// oracle for another recipient's notification (Security ADR §2, mirror of the
  /// Ledger self-read).
  Future<Result<Notification?>> findForRecipient(
    NotificationId id,
    UserId recipientId,
  );

  /// Marks the notification [id] read at [readAt], **only if it belongs to**
  /// [recipientId] and is not already read.
  ///
  /// Recipient-scoped + idempotent: returns `Ok(true)` when a row transitioned
  /// unread→read, `Ok(false)` when the notification is already read (a retried
  /// mark converges without resetting the original timestamp). A notification
  /// that is not visible to [recipientId] (foreign or absent) is reported as
  /// `Ok(null)` so the use-case can refuse it identically as
  /// `notification.not_found` (no existence oracle).
  Future<Result<bool?>> markRead(
    NotificationId id,
    UserId recipientId,
    DateTime readAt,
  );

  /// Counts [recipientId]'s unread notifications (`read_at IS NULL`).
  ///
  /// Recipient-scoped (decision #4). Always `>= 0`; zero is a legitimate
  /// result (all read, or none exist).
  Future<Result<int>> unreadCount(UserId recipientId);
}
