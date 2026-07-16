import 'package:api_client/src/api_transport.dart';
import 'package:contracts/contracts.dart';
import 'package:shared/shared.dart';

/// Typed client for the Auth (identity) surface of `apps/server`.
///
/// Wraps exactly the identity route that exists today:
///   * `GET /me` -> [MeResponseDto] (`apps/server/routes/me/index.dart`).
///
/// The route is behind `bearerAuth` (`routes/me/_middleware.dart`); an
/// unauthenticated call is refused there with `401` and surfaces here as an
/// [AppError] of kind [ErrorKind.authorization]. This client attaches the
/// bearer token supplied by the transport's [TokenProvider] — it never mints,
/// verifies, or stores a token (that is the Supabase/app concern).
final class AuthApi {
  /// Creates the Auth client over the shared [ApiTransport].
  const AuthApi(this._transport);

  final ApiTransport _transport;

  /// `GET /me` — the authenticated caller's canonical platform identity.
  ///
  /// Returns:
  ///   * `Ok(MeResponseDto)` on `200`;
  ///   * `Err(authorization)` on `401` (missing/expired/invalid token);
  ///   * `Err(transient)` on `503` or a network failure (retryable);
  ///   * `Err(validation)` if the `200` body is not a valid [MeResponseDto].
  Future<Result<MeResponseDto>> me() {
    return _transport.getObject<MeResponseDto>(
      '/me',
      parse: MeResponseDto.fromJson,
    );
  }
}
