import 'package:shared/shared.dart';

/// The identity of a [Group] aggregate root (Database ADR 0003: `Group` is the
/// Community aggregate; Axiom 2: private groups are first-class).
///
/// A value object (Coding Standards ADR, Section 2: value objects, not
/// primitives) so a group id can never be mixed with a `UserId`,
/// `SeasonId`, or any other id. Canonically a UUID matching the `group.groups`
/// primary key.
final class GroupId extends EntityId {
  /// Creates a [GroupId] from its canonical UUID string.
  ///
  /// Callers that receive untrusted input (a request path segment) should use
  /// [tryParse], which validates shape and returns a typed [Result] rather than
  /// constructing an id that might be empty or malformed.
  const GroupId(super.value);

  /// Parses a [GroupId] from an untrusted [raw] string, returning a validation
  /// [AppError] when it is absent or not a canonical (hyphenated, 36-char) UUID.
  static Result<GroupId> tryParse(String? raw) {
    if (raw == null || raw.isEmpty) {
      return const Result.err(
        AppError.validation('group.group_id_empty', 'Group id is required'),
      );
    }
    if (!_uuid.hasMatch(raw)) {
      return const Result.err(
        AppError.validation(
          'group.group_id_malformed',
          'Group id must be a UUID',
        ),
      );
    }
    return Result.ok(GroupId(raw));
  }

  /// Canonical UUID form: 8-4-4-4-12 hexadecimal, case-insensitive.
  static final RegExp _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
    r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );
}
