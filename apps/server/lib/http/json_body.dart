import 'dart:convert';

import 'package:dart_frog/dart_frog.dart';
import 'package:shared/shared.dart';

/// Reads and parses a request body as a JSON object, totally (never throws).
///
/// Command handlers speak in domain intents over a JSON body (API ADR §4). This
/// helper centralizes the transport concern of turning an untrusted body into a
/// `Map<String, Object?>`, mapping any malformation to an [ErrorKind.validation]
/// error the shared envelope renders as `400`. The edge owns *only* this
/// transport parsing; every business check lives in the use-case/domain.
///
/// An empty body is treated as an empty object, so a command whose fields are
/// all optional (none today, but forward-safe) still parses.
Future<Result<Map<String, Object?>>> readJsonObject(Request request) async {
  final String raw;
  try {
    raw = await request.body();
  } on Object {
    return const Result.err(
      AppError.validation(
        'request.body_unreadable',
        'Request body could not be read',
      ),
    );
  }

  if (raw.trim().isEmpty) {
    return const Result.ok(<String, Object?>{});
  }

  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return const Result.err(
      AppError.validation(
        'request.body_not_json',
        'Request body must be valid JSON',
      ),
    );
  }

  if (decoded is! Map<String, dynamic>) {
    return const Result.err(
      AppError.validation(
        'request.body_not_object',
        'Request body must be a JSON object',
      ),
    );
  }

  return Result.ok(Map<String, Object?>.from(decoded));
}

/// Extracts a required string field from a parsed JSON [body], mapping absence
/// or a wrong type to an [ErrorKind.validation] error. Deeper validation
/// (UUID shape, length) is the domain's job — this only asserts the transport
/// contract that the field is present and is a string.
Result<String> requireString(Map<String, Object?> body, String field) {
  final value = body[field];
  if (value is String) {
    return Result.ok(value);
  }
  return Result.err(
    AppError.validation(
      'request.field_missing',
      'Field "$field" is required and must be a string',
    ),
  );
}

/// Extracts a required integer field from a parsed JSON [body]. Accepts a JSON
/// number that is integral; rejects non-numbers and non-integral values.
Result<int> requireInt(Map<String, Object?> body, String field) {
  final value = body[field];
  if (value is int) {
    return Result.ok(value);
  }
  return Result.err(
    AppError.validation(
      'request.field_missing',
      'Field "$field" is required and must be an integer',
    ),
  );
}
