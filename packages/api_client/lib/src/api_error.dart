/// Decodes a non-2xx HTTP response from `apps/server` into the project-wide
/// typed [AppError] (the same `shared` primitive every layer already uses).
///
/// This is the exact inverse of the server's single error mapping in
/// `apps/server/lib/http/error_envelope.dart`, which derives the HTTP status
/// from the domain [ErrorKind]:
///
/// ```
/// ErrorKind.authorization -> 401
/// ErrorKind.validation    -> 400
/// ErrorKind.invariant     -> 409
/// ErrorKind.transient     -> 503
/// ```
///
/// Two client-facing read surfaces additionally build a **404** directly
/// (bypassing that mapping) while still emitting the versioned
/// [ErrorResponseDto] body — `GET /competitions/{id}`, `GET /rounds/{id}`, and
/// `GET /rounds/{id}/predictions` return 404 for a genuinely-missing resource
/// (codes `competition.not_found` / `competition.round_not_found` /
/// `prediction.not_found`). Those are semantically invariant "the resource does
/// not exist" outcomes, so a 404 maps back to [ErrorKind.invariant] here — the
/// caller branches on the stable [AppError.code], not the HTTP number.
///
/// The body is expected to be an [ErrorResponseDto] JSON object (`code` +
/// `message` + `schema_version`). When the body is missing, not JSON, or not
/// the envelope shape (e.g. an opaque proxy 502, or a bare 405 from a route's
/// method guard which carries no body), a synthetic error is produced from the
/// status alone so the transport layer is still total — it never throws.
library;

import 'dart:convert';

import 'package:contracts/contracts.dart';
import 'package:shared/shared.dart';

/// The stable error code emitted when the server replies with a status the
/// client cannot map to a known error, or with an unparseable body.
const String apiErrorUnexpectedStatus = 'api_client.unexpected_status';

/// The stable error code emitted when a 2xx response body cannot be decoded
/// into the expected DTO shape (a contract violation between client + server).
const String apiErrorMalformedResponse = 'api_client.malformed_response';

/// The stable error code emitted when the request could not reach the server
/// at all (DNS/socket/timeout) — a transient, retryable transport failure.
const String apiErrorNetworkUnreachable = 'api_client.network_unreachable';

/// Maps an HTTP [statusCode] to the [ErrorKind] the server derived it from
/// (the inverse of `error_envelope.dart`'s `_statusFor`).
///
/// * `400` -> [ErrorKind.validation]
/// * `401` -> [ErrorKind.authorization]
/// * `403` -> [ErrorKind.authorization] (defensive: a proxy/plateform 403 is an
///   access refusal even though the app maps its own authz failures to 401)
/// * `404` -> [ErrorKind.invariant] (the "resource not found" reads above)
/// * `409` -> [ErrorKind.invariant]
/// * `503` -> [ErrorKind.transient]
/// * anything else (incl. `405`, `5xx` other than 503) -> [ErrorKind.transient]
///   is deliberately NOT assumed; those map to a terminal
///   [ErrorKind.validation]-free synthetic below via [decodeError]. This helper
///   only classifies the statuses the contract actually produces.
ErrorKind? kindForStatus(int statusCode) => switch (statusCode) {
  400 => ErrorKind.validation,
  401 || 403 => ErrorKind.authorization,
  404 || 409 => ErrorKind.invariant,
  503 => ErrorKind.transient,
  _ => null,
};

/// Decodes a non-2xx response ([statusCode] + raw [body]) into an [AppError].
///
/// Total: any decoding problem degrades to a synthetic error rather than
/// throwing, so the calling client method can always return a typed
/// `Result.err` (Coding Standards ADR §4 — control flow by `Result`, never by
/// exceptions across a layer boundary).
AppError decodeError(int statusCode, String body) {
  final kind = kindForStatus(statusCode);

  // Try to read the versioned envelope so the stable server `code`/`message`
  // survive to the client (the caller branches on `code`). A route's bare
  // method-guard (`405`) or an opaque proxy error carries no such body.
  final envelope = _tryDecodeEnvelope(body);

  if (envelope != null && kind != null) {
    return AppError(kind: kind, code: envelope.code, message: envelope.message);
  }

  if (envelope != null) {
    // The server sent a valid envelope but under a status this client does not
    // model (e.g. a future status). Preserve the code/message; classify the
    // kind conservatively as transient only for 5xx, else validation-terminal.
    return AppError(
      kind: statusCode >= 500 ? ErrorKind.transient : ErrorKind.invariant,
      code: envelope.code,
      message: envelope.message,
    );
  }

  // No decodable envelope: synthesize from the status alone.
  return AppError(
    kind: statusCode >= 500 ? ErrorKind.transient : ErrorKind.validation,
    code: apiErrorUnexpectedStatus,
    message: 'The server returned an unexpected status ($statusCode).',
  );
}

/// A transient transport failure (the request never reached the server, or a
/// response could not be read) — always retryable ([ErrorKind.transient]).
AppError networkError(Object cause) => AppError(
  kind: ErrorKind.transient,
  code: apiErrorNetworkUnreachable,
  message: 'Could not reach the server. Please check your connection.',
  cause: cause,
);

/// A terminal contract violation: a 2xx body did not match the DTO shape the
/// client expected. Not retryable ([ErrorKind.validation]) — retrying an
/// identical malformed payload will not help; it signals a client/server
/// contract drift.
AppError malformedResponse(Object cause) => AppError(
  kind: ErrorKind.validation,
  code: apiErrorMalformedResponse,
  message: 'The server response could not be understood.',
  cause: cause,
);

ErrorResponseDto? _tryDecodeEnvelope(String body) {
  if (body.isEmpty) return null;
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map) return null;
    final map = decoded.cast<String, Object?>();
    // Require the two mandatory envelope fields to be present + typed; a random
    // JSON object that happens to parse is not an error envelope.
    if (map['code'] is! String || map['message'] is! String) return null;
    return ErrorResponseDto.fromJson(map);
  } on FormatException {
    return null;
  }
}
