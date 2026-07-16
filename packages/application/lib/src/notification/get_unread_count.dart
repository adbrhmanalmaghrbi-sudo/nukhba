import 'package:application/src/identity/authorization.dart';
import 'package:application/src/notification/ports/notification_repository.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// Query use-case: read the caller's OWN unread-notification count
/// (Application ADR §2: a query intent, for a badge/indicator).
///
/// **Recipient-only gate (decision #4):** the count is scoped to the verified
/// [AuthenticatedUser.userId] — no group/season membership check. The recipient
/// is always the principal, never a body (Security ADR §2). The result is always
/// `>= 0`; zero is legitimate (all read, or none exist).
///
/// **Tier-3 (decision #4; ADR 0007 §2.4):** a failure is confined to this read
/// and never blocks a Tier-1 core operation.
///
/// Never throws; returns a typed [Result].
final class GetUnreadCount {
  /// Creates the use-case over its single collaborator.
  const GetUnreadCount({required NotificationRepository notifications})
    : _notifications = notifications;

  final NotificationRepository _notifications;

  /// Returns [principal]'s own unread-notification count.
  Future<Result<int>> call({required AuthenticatedUser principal}) async {
    // Layer 1: platform authority — any signed-in user.
    final auth = Authorization.requireRole(principal, PlatformRole.user);
    if (auth is Err<AuthenticatedUser>) {
      return Result.err(auth.error);
    }

    // Layer 2 (visibility): recipient-only — the caller's own count only.
    return _notifications.unreadCount(principal.userId);
  }
}
