import 'package:domain/src/identity/platform_role.dart';
import 'package:domain/src/identity/user_id.dart';

/// The request principal: who the backend has *cryptographically established*
/// is making the current request, derived from a verified Supabase JWT
/// (Security ADR, Section 2; Application ADR, Section 12).
///
/// This is deliberately narrower than [User]. It carries only what a verified
/// token asserts — identity, authority, and a minimal, safe subset of claims —
/// not the platform's full record of the user (that is [User], loaded from the
/// directory). Keeping them separate stops route/handler code from trusting
/// token-sourced fields as if they were canonical platform state.
///
/// Pure and immutable; carries no framework or IO knowledge.
final class AuthenticatedUser {
  /// Creates a request principal from already-verified token facts.
  const AuthenticatedUser({
    required this.userId,
    required this.role,
    this.email,
  });

  /// The verified subject identity (JWT `sub`).
  final UserId userId;

  /// The platform authority resolved from the verified token (first
  /// authorization layer). Never trusted from the client directly — always the
  /// output of server-side verification + mapping.
  final PlatformRole role;

  /// The verified email claim, if the token carried one. Optional because
  /// phone-only or service principals may have none.
  final String? email;

  /// Whether this principal holds the given platform [required] role.
  ///
  /// A [PlatformRole.admin] principal satisfies a [PlatformRole.user]
  /// requirement (admins are a superset of user authority); a
  /// [PlatformRole.service] principal satisfies any role requirement. This is
  /// the single place the role hierarchy is defined so authorization stays
  /// consistent across use-cases.
  bool hasRole(PlatformRole required) {
    if (role == PlatformRole.service) return true;
    if (required == PlatformRole.user) {
      return role == PlatformRole.user || role == PlatformRole.admin;
    }
    return role == required;
  }

  @override
  bool operator ==(Object other) =>
      other is AuthenticatedUser &&
      other.userId == userId &&
      other.role == role &&
      other.email == email;

  @override
  int get hashCode => Object.hash(userId, role, email);

  @override
  String toString() => 'AuthenticatedUser(${userId.value}, role: ${role.name})';
}
