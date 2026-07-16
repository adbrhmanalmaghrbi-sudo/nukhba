import 'package:application/src/identity/authorization.dart';
import 'package:application/src/notification/ports/notification_repository.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// Query use-case: read the caller's OWN notifications, newest-first
/// (Application ADR §2: a query intent separated from commands).
///
/// **Recipient-only gate (decision #4):** the list is scoped to the verified
/// [AuthenticatedUser.userId] — there is no group/season membership check (a
/// materially simpler gate than every phase since Groups). The recipient is
/// always the principal, never a body (Security ADR §2), so a caller can never
/// read another user's notifications.
///
/// [limit] is clamped to `[1, maxLimit]`; a null or non-positive value falls
/// back to [defaultLimit] so a Tier-3 read never triggers an unbounded scan
/// (decision #4; ADR 0007 §2.4). An empty list is legitimate (a recipient with
/// no notifications).
///
/// Never throws; returns a typed [Result].
final class ListMyNotifications {
  /// Creates the use-case over its single collaborator.
  const ListMyNotifications({required NotificationRepository notifications})
    : _notifications = notifications;

  final NotificationRepository _notifications;

  /// The default number of notifications returned when a caller does not
  /// specify a [limit].
  static const int defaultLimit = 50;

  /// The hard upper bound on how many notifications a single read may return, so
  /// an untrusted [limit] can never ask for an unbounded scan (decision #4).
  static const int maxLimit = 200;

  /// Reads [principal]'s own notifications, newest-first. [limit] is clamped to
  /// `[1, maxLimit]`; null/non-positive falls back to [defaultLimit].
  Future<Result<List<Notification>>> call({
    required AuthenticatedUser principal,
    int? limit,
  }) async {
    // Layer 1: platform authority — any signed-in user.
    final auth = Authorization.requireRole(principal, PlatformRole.user);
    if (auth is Err<AuthenticatedUser>) {
      return Result.err(auth.error);
    }

    // Layer 2 (visibility): recipient-only — the caller reads exactly their own
    // notifications (decision #4). No membership check.
    final effectiveLimit = _clampLimit(limit);
    return _notifications.listForRecipient(
      principal.userId,
      limit: effectiveLimit,
    );
  }

  int _clampLimit(int? limit) {
    if (limit == null || limit <= 0) {
      return defaultLimit;
    }
    if (limit > maxLimit) {
      return maxLimit;
    }
    return limit;
  }
}
