import 'package:shared/shared.dart';

/// The identity of a [Notification] aggregate root — a single in-app
/// notification addressed to one recipient `User` (Notifications phase; Database
/// ADR 0003 §2.2/§3: Notification owns its own Tier-3 table, rebuildable,
/// never a source of truth).
///
/// A value object (Coding Standards ADR, Section 2), canonically a UUID matching
/// the `notification.notifications` primary key. Kept a distinct id type from
/// `UserId`/`RoundId`/`GroupId`/`ReactionId` so a notification row is never
/// addressed by a user, round, group, or reaction id by mistake.
final class NotificationId extends EntityId {
  /// Creates a [NotificationId] from its canonical UUID string.
  ///
  /// Callers that receive untrusted input should use [tryParse], which validates
  /// shape and returns a typed [Result] rather than constructing an id that
  /// might be empty or malformed.
  const NotificationId(super.value);

  /// Parses a [NotificationId] from an untrusted [raw] string, returning a
  /// validation [AppError] when it is absent or not a canonical (hyphenated,
  /// 36-char) UUID.
  static Result<NotificationId> tryParse(String? raw) {
    if (raw == null || raw.isEmpty) {
      return const Result.err(
        AppError.validation(
          'notification.notification_id_empty',
          'Notification id is required',
        ),
      );
    }
    if (!_uuid.hasMatch(raw)) {
      return const Result.err(
        AppError.validation(
          'notification.notification_id_malformed',
          'Notification id must be a UUID',
        ),
      );
    }
    return Result.ok(NotificationId(raw));
  }

  /// Canonical UUID form: 8-4-4-4-12 hexadecimal, case-insensitive.
  static final RegExp _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
    r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );
}
