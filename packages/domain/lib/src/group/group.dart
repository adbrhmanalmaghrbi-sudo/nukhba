import 'package:domain/src/group/group_id.dart';
import 'package:domain/src/group/invite_code.dart';
import 'package:domain/src/identity/user_id.dart';
import 'package:shared/shared.dart';

/// The Community aggregate root (Database ADR 0003; Axiom 2: private groups are
/// first-class from the architectural root).
///
/// A [Group] is an **orthogonal social container** — a named circle of platform
/// users identified by their [UserId]s — NOT a competition owner or scope
/// (Groups decision #1, project-context §2). It therefore carries **no**
/// competition/season/round reference: the frozen Competition/Round/Prediction/
/// Leaderboard surfaces are untouched (Axiom 4, group-free by ratified design).
///
/// A group is created by exactly one [ownerId] (the sole `owner`-role member),
/// has a human display [name], and holds a shareable [inviteCode] — the
/// zero-friction join capability (decisions #2/#3: invite-only, no existence
/// oracle). Management authority (rename/regenerate/remove) belongs to the owner
/// and is enforced in the use-cases, not here — an aggregate reasons only about
/// itself and cannot see who is calling (mirror of `Participant`).
///
/// Pure and immutable: no framework, no IO. State changes produce new values;
/// the entity is value-comparable.
final class Group {
  const Group._({
    required this.id,
    required this.ownerId,
    required this.name,
    required this.inviteCode,
    required this.createdAt,
  });

  /// Rehydrates a [Group] from already-trusted stored fields (used by the
  /// infrastructure mapper). Performs no validation beyond typing — callers
  /// creating a *new* group from untrusted input must use [create].
  const Group.fromStored({
    required this.id,
    required this.ownerId,
    required this.name,
    required this.inviteCode,
    required this.createdAt,
  });

  /// Creates a new group from validated inputs.
  ///
  /// [name] is trimmed and length-checked (1–[maxNameLength] chars after
  /// trimming), mirroring `Competition.create`'s name discipline, so an empty or
  /// oversized name is rejected as a validation failure rather than persisted.
  /// [createdAt] must be a UTC instant (callers normalize) so audit ordering is
  /// unambiguous. [id] and [inviteCode] are already validated value objects
  /// (generated server-side), so they need no further checking here.
  static Result<Group> create({
    required GroupId id,
    required UserId ownerId,
    required String name,
    required InviteCode inviteCode,
    required DateTime createdAt,
  }) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      return const Result.err(
        AppError.validation('group.name_empty', 'Group name is required'),
      );
    }
    if (trimmed.length > maxNameLength) {
      return const Result.err(
        AppError.validation(
          'group.name_too_long',
          'Group name must be at most $maxNameLength characters',
        ),
      );
    }
    if (!createdAt.isUtc) {
      return const Result.err(
        AppError.validation(
          'group.created_at_not_utc',
          'createdAt must be provided in UTC',
        ),
      );
    }
    return Result.ok(
      Group._(
        id: id,
        ownerId: ownerId,
        name: trimmed,
        inviteCode: inviteCode,
        createdAt: createdAt,
      ),
    );
  }

  /// The maximum display-name length (kept a little tighter than a
  /// competition's, since a group name is a small social label).
  static const int maxNameLength = 80;

  /// The aggregate identity.
  final GroupId id;

  /// The creating user — the sole [group owner]. Fixed for the life of the
  /// group (ownership transfer is not a v1 capability — decision #2).
  final UserId ownerId;

  /// The display name (trimmed, 1–[maxNameLength] chars).
  final String name;

  /// The current shareable invite code (the join capability). Rotated by
  /// [regenerateInvite]; only ever surfaced to a member (decision #3).
  final InviteCode inviteCode;

  /// When the group was created (UTC).
  final DateTime createdAt;

  /// Returns a copy with a new, validated [name].
  ///
  /// Applies the same trim/length discipline as [create]. Does NOT check caller
  /// authority — the owner-only gate lives in `RenameGroup` (an aggregate cannot
  /// see the principal).
  Result<Group> rename(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      return const Result.err(
        AppError.validation('group.name_empty', 'Group name is required'),
      );
    }
    if (trimmed.length > maxNameLength) {
      return const Result.err(
        AppError.validation(
          'group.name_too_long',
          'Group name must be at most $maxNameLength characters',
        ),
      );
    }
    return Result.ok(
      Group._(
        id: id,
        ownerId: ownerId,
        name: trimmed,
        inviteCode: inviteCode,
        createdAt: createdAt,
      ),
    );
  }

  /// Returns a copy carrying a freshly-generated [inviteCode] (invalidating the
  /// previous one — a shared link can be revoked). Authority is enforced in
  /// `RegenerateInvite`, not here.
  Group regenerateInvite(InviteCode newCode) {
    return Group._(
      id: id,
      ownerId: ownerId,
      name: name,
      inviteCode: newCode,
      createdAt: createdAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Group &&
      other.id == id &&
      other.ownerId == ownerId &&
      other.name == name &&
      other.inviteCode == inviteCode &&
      other.createdAt == createdAt;

  @override
  int get hashCode => Object.hash(id, ownerId, name, inviteCode, createdAt);

  @override
  String toString() => 'Group(${id.value}, "$name", owner: ${ownerId.value})';
}
