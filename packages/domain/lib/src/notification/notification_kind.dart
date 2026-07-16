import 'package:shared/shared.dart';

/// The **closed, fixed set** of notification kinds delivered in v1
/// (Notifications decision #1: a minimal high-value trigger surface, NOT a full
/// enumeration of every domain event).
///
/// The domain owns the *set*; the copy/glyph a user sees is a *client*
/// presentation concern. What travels over the wire and is stored is a stable
/// token ([wireValue]) — exactly as `ReactionKind`/`GroupRole` carry wire
/// tokens, not presentation. An unknown token from storage or the wire is a
/// validation failure, never silently coerced.
///
/// The three kinds map one-to-one to the ratified trigger events (Notifications
/// decision #1); extending the set is a forward-only schema + enum change.
enum NotificationKind {
  /// A round the recipient participates in was scored (its results were
  /// posted). The single most-awaited moment in the predict-once loop.
  /// Subject references the scored round.
  roundScored,

  /// A new member joined a group the recipient owns (v1 notifies the group
  /// owner only — decision #1, avoiding an N² fan-out). Subject references the
  /// group and the joining user.
  groupMemberJoined,

  /// Another member reacted to a round-result in a group the recipient is a
  /// member of, targeting a round the recipient participated in ("someone
  /// reacted to your prediction"). Subject references the group, the round, and
  /// the reacting user.
  reactionReceived;

  /// The stable wire/storage token for this notification kind.
  String get wireValue => switch (this) {
    NotificationKind.roundScored => 'round_scored',
    NotificationKind.groupMemberJoined => 'group_member_joined',
    NotificationKind.reactionReceived => 'reaction_received',
  };

  /// Parses a [NotificationKind] from an untrusted [raw] token, returning a
  /// validation [AppError] when it is absent or unrecognized. Kept total so an
  /// unknown token is a typed validation error, never silently coerced.
  static Result<NotificationKind> tryParse(String? raw) {
    for (final value in NotificationKind.values) {
      if (value.wireValue == raw) {
        return Result.ok(value);
      }
    }
    return Result.err(
      AppError.validation(
        'notification.kind_unknown',
        'Unknown notification kind: ${raw ?? '<null>'}',
      ),
    );
  }
}
