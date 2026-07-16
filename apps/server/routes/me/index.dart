import 'dart:io';

import 'package:contracts/contracts.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:domain/domain.dart';
import 'package:server/composition/composition_root.dart';
import 'package:server/http/error_envelope.dart';
import 'package:shared/shared.dart';

/// GET /me — returns the authenticated caller's canonical platform identity
/// (API ADR, Section 2: this is a *query*, command/query separated).
///
/// The request is already authenticated by the `bearerAuth` middleware in
/// `routes/me/_middleware.dart`, which provides the verified
/// [AuthenticatedUser] into the context; an unauthenticated request is rejected
/// there and never reaches this handler. Here we resolve the platform's
/// authoritative [User] record via the [GetCurrentUser] use-case (ensuring the
/// row exists on first sight) and project it to the versioned [MeResponseDto].
///
/// The returned role/status are the platform-owned values from the directory,
/// not the token's claims — the token established *who* the caller is; the
/// platform decides *what* it records about them (Security ADR, Section 2).
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final root = await context.read<Future<CompositionRoot>>();
  final principal = context.read<AuthenticatedUser>();

  final result = await root.getCurrentUser(principal);

  return switch (result) {
    Ok<User>(:final value) => Response.json(
      body: MeResponseDto(
        user: AuthenticatedUserDto(
          userId: value.id.value,
          role: value.role.name,
          status: value.status.name,
          email: value.email,
        ),
      ).toJson(),
    ),
    // A transient directory failure maps to 503 via the shared envelope so the
    // client can retry; no other error kind is expected on this path.
    Err<User>(:final error) => errorResponse(error),
  };
}
