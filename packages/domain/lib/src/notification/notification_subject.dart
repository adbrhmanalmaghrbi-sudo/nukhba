import 'package:domain/src/competition/round_id.dart';
import 'package:domain/src/group/group_id.dart';
import 'package:domain/src/identity/user_id.dart';
import 'package:domain/src/notification/notification_kind.dart';
import 'package:shared/shared.dart';

/// The bounded, **kind-discriminated reference payload** of a [Notification]
/// (Notifications decision #1/#3): the type-specific ids a client needs to
/// render the notification and deep-link into the platform, plus a
/// deterministic [dedupeRef] that keys the idempotency constraint.
///
/// Discriminated by [NotificationKind]:
/// * `roundScored` — [roundId] set; group/actor null.
/// * `groupMemberJoined` — [groupId] + [actorUserId] (the joiner) set; round
///   null.
/// * `reactionReceived` — [groupId] + [roundId] + [actorUserId] (the reactor)
///   set.
///
/// The named factories validate that exactly the right references are present
/// for the kind (an aggregate reasons about its own shape). [dedupeRef] is a
/// stable string derived purely from the subject, so re-triggering the SAME
/// event produces the SAME ref (a replay dedupes on `(recipientId, kind,
/// dedupeRef)`) while a DISTINCT event produces a distinct ref.
///
/// Carries **NO points field** (Axiom 5 — Notifications is never a second
/// points source) and **NO free-text / open-graph edge** (decision #1;
/// ADR-001). Pure, immutable, value-comparable.
final class NotificationSubject {
  const NotificationSubject._({
    required this.kind,
    this.roundId,
    this.groupId,
    this.actorUserId,
  });

  /// Rehydrates a subject from already-trusted stored fields (used by the
  /// infrastructure mapper). Performs no cross-field validation beyond typing —
  /// callers building a *new* subject from a domain event must use the named
  /// factories.
  const NotificationSubject.fromStored({
    required this.kind,
    this.roundId,
    this.groupId,
    this.actorUserId,
  });

  /// The subject of a `roundScored` notification — the scored [roundId].
  static NotificationSubject roundScored({required RoundId roundId}) =>
      NotificationSubject._(
        kind: NotificationKind.roundScored,
        roundId: roundId,
      );

  /// The subject of a `groupMemberJoined` notification — the [groupId] and the
  /// joining [actorUserId].
  static NotificationSubject groupMemberJoined({
    required GroupId groupId,
    required UserId actorUserId,
  }) => NotificationSubject._(
    kind: NotificationKind.groupMemberJoined,
    groupId: groupId,
    actorUserId: actorUserId,
  );

  /// The subject of a `reactionReceived` notification — the [groupId], the
  /// target [roundId], and the reacting [actorUserId].
  static NotificationSubject reactionReceived({
    required GroupId groupId,
    required RoundId roundId,
    required UserId actorUserId,
  }) => NotificationSubject._(
    kind: NotificationKind.reactionReceived,
    groupId: groupId,
    roundId: roundId,
    actorUserId: actorUserId,
  );

  /// The kind this subject belongs to (matches the owning notification's kind).
  final NotificationKind kind;

  /// The round involved (`roundScored`, `reactionReceived`); else null.
  final RoundId? roundId;

  /// The group involved (`groupMemberJoined`, `reactionReceived`); else null.
  final GroupId? groupId;

  /// The acting user (`groupMemberJoined` = the joiner, `reactionReceived` =
  /// the reactor); else null.
  final UserId? actorUserId;

  /// A deterministic string that identifies the originating event, keying the
  /// `(recipientId, kind, subjectRef)` idempotency constraint so a replayed
  /// trigger dedupes and a distinct event does not. Built purely from the
  /// subject references — no clock, no random component — so it is stable
  /// across replays.
  String get dedupeRef => switch (kind) {
    NotificationKind.roundScored => 'round:${roundId!.value}',
    NotificationKind.groupMemberJoined =>
      'group_join:${groupId!.value}:${actorUserId!.value}',
    NotificationKind.reactionReceived =>
      'reaction:${groupId!.value}:${roundId!.value}:${actorUserId!.value}',
  };

  @override
  bool operator ==(Object other) =>
      other is NotificationSubject &&
      other.kind == kind &&
      other.roundId == roundId &&
      other.groupId == groupId &&
      other.actorUserId == actorUserId;

  @override
  int get hashCode => Object.hash(kind, roundId, groupId, actorUserId);

  @override
  String toString() => 'NotificationSubject(${kind.wireValue}, $dedupeRef)';
}
