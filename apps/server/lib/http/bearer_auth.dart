import 'dart:io';

import 'package:application/application.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:domain/domain.dart';
import 'package:server/composition/composition_root.dart';
import 'package:server/http/error_envelope.dart';
import 'package:shared/shared.dart';

/// Middleware that enforces Supabase bearer authentication on the routes it
/// guards, and provides the established [AuthenticatedUser] principal to
/// downstream handlers (Security ADR, Section 2; Application ADR, Section 12).
///
/// It is applied *per protected route subtree*, never globally — public routes
/// such as `/health` must not require a token (Roadmap ADR: `/health` stays
/// public). A route (or route group) opts in by adding this middleware in its
/// own `_middleware.dart`.
///
/// Flow for every guarded request:
/// 1. Read the raw `Authorization` header (may be absent).
/// 2. Delegate parsing + cryptographic verification to the
///    [AuthenticateRequest] use-case resolved from the composition root — the
///    edge owns *no* auth logic itself, only transport concerns.
/// 3. On success, provide the [AuthenticatedUser] to the request context so the
///    protected handler can `context.read<AuthenticatedUser>()` without
///    re-verifying.
/// 4. On failure, short-circuit with the uniform error envelope; the status is
///    derived from the domain [AppError.kind] (401 for authorization failures,
///    503 if verification material was transiently unreachable) — the handler
///    is never reached.
///
/// The principal is provided as a resolved value (not a future): verification
/// has already completed by the time the handler runs, so downstream reads are
/// synchronous and cannot observe an unauthenticated request.
Middleware bearerAuth() {
  return (handler) {
    return (context) async {
      final root = await context.read<Future<CompositionRoot>>();

      // dart_frog lowercases header names; `authorizationHeader` is the
      // canonical lowercase `'authorization'` key.
      final header = context.request.headers[HttpHeaders.authorizationHeader];

      final result = await root.authenticateRequest(header);

      return switch (result) {
        Ok<AuthenticatedUser>(:final value) => await handler(
          context.provide<AuthenticatedUser>(() => value),
        ),
        // Terminal (401) or transient (503) — errorResponse maps the kind.
        Err<AuthenticatedUser>(:final error) => errorResponse(error),
      };
    };
  };
}
