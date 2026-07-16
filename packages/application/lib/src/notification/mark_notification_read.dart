import 'package:application/src/common/clock.dart';
import 'package:application/src/identity/authorization.dart';
import 'package:application/src/notification/ports/notification_repository.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// Command use-case: mark the caller's OWN notification read (Application ADR
/// §2: a command intent `MarkNotificationRead`).
///
/// **Recipient-only gate (decision #4):** a caller may mark read only a
/// notification they own. A notification that is foreign or does not exist is
/// refused identically as [ErrorKind.authorization] `notification.not_found`
/// (NO existence oracle — mirror of the Ledger self-read
/// `participant_not_found`, NOT the Groups member gate). The recipient is always
/// the verified principal, never a body (Security ADR §2).
///
/// **Idempotent** (decision #3, mirror of the domain [Notification.markRead]):
/// marking an already-read notification is a success that does NOT reset the
/// original read timestamp — a retried mark converges. The mark is delegated to
/// [NotificationRepository.markRead], which is recipient-scoped in the query so
/// a foreign id updates nothing.
///
/// The read timestamp is stamped from the injected [Clock] (UTC) so tests assert
/// exact timestamps and all instants share one zone.
///
/// Never throws; returns a typed [Result] carrying `true` when the notification
/// transitioned unread→read, `false` when it was already read (idempotent).
final class MarkNotificationRead {
  /// Creates the use-case over its collaborators.
  const MarkNotificationRead({
    required NotificationRepository notifications,
    required Clock clock,
  }) : _notifications = notifications,
       _clock = clock;

  final NotificationRepository _notifications;
  final Clock _clock;

  /// Marks the notification [notificationId] read on behalf of [principal],
  /// who must be its recipient.
  Future<Result<bool>> call({
    required AuthenticatedUser principal,
    required String notificationId,
  }) async {
    // Layer 1: platform authority — any signed-in user.
    final auth = Authorization.requireRole(principal, PlatformRole.user);
    if (auth is Err<AuthenticatedUser>) {
      return Result.err(auth.error);
    }

    final idResult = NotificationId.tryParse(notificationId);
    if (idResult is Err<NotificationId>) {
      return Result.err(idResult.error);
    }
    final id = (idResult as Ok<NotificationId>).value;

    // Layer 2 (visibility): recipient-scoped mark. A foreign/unknown id updates
    // nothing → the repository reports `Ok(null)`, which we refuse identically
    // as `notification.not_found` (no existence oracle — decision #4).
    final marked = await _notifications.markRead(
      id,
      principal.userId,
      _clock.nowUtc(),
    );
    return switch (marked) {
      Err<bool?>(:final error) => Result.err(error),
      Ok<bool?>(value: null) => Result.err(
        const AppError.authorization(
          'notification.not_found',
          'No such notification is visible to this caller',
        ),
      ),
      Ok<bool?>(value: final changed?) => Result.ok(changed),
    };
  }
}
