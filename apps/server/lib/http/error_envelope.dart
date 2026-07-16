import 'dart:io';

import 'package:contracts/contracts.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:shared/shared.dart';

/// Maps a domain [AppError] to an HTTP response using the uniform error
/// envelope (API ADR, Section 5: the edge derives the status from the domain
/// error *class*; the body is the versioned [ErrorResponseDto]).
///
/// This is the single place the `ErrorKind -> status` mapping lives, so every
/// route reports failures identically:
///   * [ErrorKind.authorization] -> 401 Unauthorized (the caller is not, or
///     not sufficiently, authenticated for this request).
///   * [ErrorKind.validation]    -> 400 Bad Request.
///   * [ErrorKind.invariant]     -> 409 Conflict (a business rule was
///     violated; used by later domain phases).
///   * [ErrorKind.transient]     -> 503 Service Unavailable (retryable).
///
/// The [AppError.cause] is never serialized — it is server-only detail. Only
/// the stable [AppError.code] and safe [AppError.message] cross the wire.
Response errorResponse(AppError error) {
  return Response.json(
    statusCode: _statusFor(error.kind),
    body: ErrorResponseDto(code: error.code, message: error.message).toJson(),
  );
}

int _statusFor(ErrorKind kind) => switch (kind) {
  ErrorKind.authorization => HttpStatus.unauthorized,
  ErrorKind.validation => HttpStatus.badRequest,
  ErrorKind.invariant => HttpStatus.conflict,
  ErrorKind.transient => HttpStatus.serviceUnavailable,
};
