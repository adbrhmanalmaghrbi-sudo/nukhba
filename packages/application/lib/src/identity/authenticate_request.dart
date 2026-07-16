import 'package:application/src/identity/ports/token_verifier.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// Use-case: establish the request principal from a raw `Authorization` header
/// value (Security ADR, Section 2: verify the token server-side before mapping
/// to the domain `User`; Application ADR, Section 12).
///
/// This is the single entry point the edge calls to authenticate a request. It
/// owns the parse of the `Bearer <token>` scheme so no route re-implements it,
/// then delegates cryptographic verification to the [TokenVerifier] port.
///
/// Never throws; every outcome is a typed [Result] with the correct
/// [ErrorKind] so the edge can map it to an HTTP status (ADR 0004, Section 5).
final class AuthenticateRequest {
  /// Creates the use-case over its [TokenVerifier] port.
  const AuthenticateRequest(this._verifier);

  final TokenVerifier _verifier;

  /// The `Bearer ` scheme prefix, matched case-insensitively per RFC 7235.
  static const String _bearerPrefix = 'bearer ';

  /// Authenticates a request from its raw [authorizationHeader]
  /// (the full header value, e.g. `Bearer eyJ...`, or `null` if absent).
  ///
  /// Returns [ErrorKind.authorization] when the header is missing or not a
  /// well-formed bearer credential; otherwise the port's result (which may be a
  /// transient error if verification material was unreachable).
  Future<Result<AuthenticatedUser>> call(String? authorizationHeader) async {
    final token = _extractBearer(authorizationHeader);
    if (token == null) {
      return const Result.err(
        AppError.authorization(
          'auth.missing_bearer',
          'Missing or malformed Authorization: Bearer token',
        ),
      );
    }
    return _verifier.verify(token);
  }

  /// Extracts the raw token from a `Bearer <token>` header, or `null` if the
  /// header is absent, uses a different scheme, or carries an empty token.
  static String? _extractBearer(String? header) {
    if (header == null) return null;
    final trimmed = header.trim();
    if (trimmed.length <= _bearerPrefix.length) return null;
    final scheme = trimmed.substring(0, _bearerPrefix.length).toLowerCase();
    if (scheme != _bearerPrefix) return null;
    final token = trimmed.substring(_bearerPrefix.length).trim();
    return token.isEmpty ? null : token;
  }
}
