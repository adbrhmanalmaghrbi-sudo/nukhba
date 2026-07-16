import 'package:shared/shared.dart';

/// The shareable, unguessable token that lets a friend join a private [Group]
/// in one step (Groups decision #2: zero-friction instant join; decision #3:
/// invite-only discovery, no existence oracle for non-members).
///
/// A value object (Coding Standards ADR, Section 2). The domain owns the token's
/// *shape* — a fixed-length string drawn from an unambiguous, URL-safe alphabet
/// — so an untrusted join token is validated to that shape before it is ever
/// used as a lookup key (a lookup on arbitrary input would be an enumeration
/// oracle). The actual random *generation* is an application concern (the
/// `InviteCodeGenerator` port), kept out of the pure domain exactly as ids come
/// from `IdGenerator`; this class only validates and carries the value.
///
/// The alphabet excludes visually ambiguous characters (`0/O`, `1/I/l`) so a
/// code shared verbally or typed by hand is unambiguous; length [codeLength]
/// gives a large enough space that guessing a live code is infeasible.
final class InviteCode {
  const InviteCode._(this.value);

  /// The canonical string form of the invite code (upper-case alphanumeric,
  /// [codeLength] characters from [_alphabet]).
  final String value;

  /// The fixed length of a well-formed invite code. Chosen so the space
  /// (`alphabet^length`) is far too large to enumerate.
  static const int codeLength = 10;

  /// The closed, URL-safe alphabet: upper-case letters and digits with the
  /// visually ambiguous `0 O 1 I L` removed.
  static const String _alphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';

  /// Whether [character] is a member of the invite-code alphabet. Exposed so the
  /// application generator draws from exactly the shape the domain validates.
  static bool isAllowedChar(String character) => _alphabet.contains(character);

  /// The alphabet a compliant generator must draw from.
  static String get alphabet => _alphabet;

  /// Parses an [InviteCode] from an untrusted [raw] token.
  ///
  /// Returns a validation [AppError] when [raw] is absent, the wrong length, or
  /// contains a character outside the closed alphabet. Kept total so a join
  /// attempt with a malformed code fails as a typed validation error rather than
  /// reaching the repository as an arbitrary lookup string.
  static Result<InviteCode> tryParse(String? raw) {
    if (raw == null || raw.isEmpty) {
      return const Result.err(
        AppError.validation(
          'group.invite_code_empty',
          'Invite code is required',
        ),
      );
    }
    if (raw.length != codeLength) {
      return const Result.err(
        AppError.validation(
          'group.invite_code_malformed',
          'Invite code must be exactly $codeLength characters',
        ),
      );
    }
    for (var i = 0; i < raw.length; i++) {
      if (!_alphabet.contains(raw[i])) {
        return const Result.err(
          AppError.validation(
            'group.invite_code_malformed',
            'Invite code contains an unsupported character',
          ),
        );
      }
    }
    return Result.ok(InviteCode._(raw));
  }

  @override
  bool operator ==(Object other) => other is InviteCode && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'InviteCode($value)';
}
