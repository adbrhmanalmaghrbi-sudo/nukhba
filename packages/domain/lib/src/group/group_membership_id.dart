import 'package:shared/shared.dart';

/// The identity of a [GroupMembership] aggregate root — a user's row in a
/// [Group] (Axiom 2; Database ADR 0003 Community aggregate).
///
/// A value object (Coding Standards ADR, Section 2), canonically a UUID matching
/// the `group.group_memberships` primary key. Kept a distinct id type from
/// `GroupId`/`UserId` so a membership row is never addressed by a group or user
/// id by mistake.
final class GroupMembershipId extends EntityId {
  /// Creates a [GroupMembershipId] from its canonical UUID string.
  const GroupMembershipId(super.value);

  /// Parses a [GroupMembershipId] from an untrusted [raw] string, returning a
  /// validation [AppError] when it is absent or not a canonical UUID.
  static Result<GroupMembershipId> tryParse(String? raw) {
    if (raw == null || raw.isEmpty) {
      return const Result.err(
        AppError.validation(
          'group.membership_id_empty',
          'Group membership id is required',
        ),
      );
    }
    if (!_uuid.hasMatch(raw)) {
      return const Result.err(
        AppError.validation(
          'group.membership_id_malformed',
          'Group membership id must be a UUID',
        ),
      );
    }
    return Result.ok(GroupMembershipId(raw));
  }

  static final RegExp _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
    r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );
}
