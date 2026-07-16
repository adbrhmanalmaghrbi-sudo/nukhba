import 'package:shared/shared.dart';

/// A member's role *within a single [Group]* — the per-group authority layer,
/// deliberately distinct from the platform-wide `PlatformRole` (which
/// `identity/platform_role.dart` already notes is separate from any per-group
/// role a social phase would introduce).
///
/// The set is closed and minimal for v1 (Groups decision #2, project-context
/// §2): there is NO intermediate `admin` tier. An unknown role token from
/// storage or the wire is a validation failure, never silently coerced.
enum GroupRole {
  /// The group's creator. Exactly one per group. May rename the group, remove
  /// members, and regenerate the invite code. Authority over these actions is
  /// enforced in the group use-cases (an aggregate reasons only about itself),
  /// not by this enum alone.
  owner,

  /// An ordinary member who joined via the invite code. May read the group and
  /// its member-scoped leaderboard, but performs no group-management action.
  member;

  /// The stable wire/storage token for this role.
  String get wireValue => switch (this) {
    GroupRole.owner => 'owner',
    GroupRole.member => 'member',
  };

  /// Whether this role is the group [owner] (the only management authority).
  bool get isOwner => this == GroupRole.owner;

  /// Parses a [GroupRole] from an untrusted [raw] token, returning a validation
  /// [AppError] when it is absent or unrecognized.
  static Result<GroupRole> tryParse(String? raw) {
    for (final value in GroupRole.values) {
      if (value.wireValue == raw) {
        return Result.ok(value);
      }
    }
    return Result.err(
      AppError.validation(
        'group.role_unknown',
        'Unknown group role: ${raw ?? '<null>'}',
      ),
    );
  }
}
