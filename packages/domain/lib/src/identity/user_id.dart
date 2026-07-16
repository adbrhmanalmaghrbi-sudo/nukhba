import 'package:shared/shared.dart';

/// The identity of a platform [User], carried as a value object rather than a
/// raw string so distinct id types cannot be mixed (Coding Standards ADR,
/// Section 2: value objects, not primitives).
///
/// The canonical form is the Supabase Auth user UUID (the JWT `sub` claim),
/// which is also the primary key of `identity.users` (Database ADR, Section 3:
/// `User` is the Identity aggregate root).
final class UserId extends EntityId {
  /// Creates a [UserId] from its canonical UUID string.
  ///
  /// Callers that receive untrusted input (e.g. a decoded JWT claim) should use
  /// [tryParse], which validates shape and returns a typed [Result] instead of
  /// constructing an id that might be empty or malformed.
  const UserId(super.value);

  /// Parses a [UserId] from an untrusted [raw] string.
  ///
  /// Returns a validation [AppError] when [raw] is `null`, empty, or not a
  /// canonical (hyphenated, 36-char) UUID. Kept total so no exception escapes
  /// into the auth path.
  static Result<UserId> tryParse(String? raw) {
    if (raw == null || raw.isEmpty) {
      return const Result.err(
        AppError.validation('identity.user_id_empty', 'User id is required'),
      );
    }
    if (!_uuid.hasMatch(raw)) {
      return const Result.err(
        AppError.validation(
          'identity.user_id_malformed',
          'User id must be a UUID',
        ),
      );
    }
    return Result.ok(UserId(raw));
  }

  /// Canonical UUID form: 8-4-4-4-12 hexadecimal, case-insensitive. Matches the
  /// shape Supabase Auth issues for the `sub` claim and stores as the user PK.
  static final RegExp _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
    r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );
}
