/// The uniform error envelope for every non-2xx API response (API ADR,
/// Section 5: errors are typed and carry a stable machine-readable code plus a
/// safe human message; the HTTP status is derived by the edge from the domain
/// error class).
///
/// A pure, versioned data shape shared by client and server. It never carries
/// secrets, stack traces, or the underlying cause — those stay server-side.
final class ErrorResponseDto {
  /// Creates an error envelope.
  const ErrorResponseDto({
    required this.code,
    required this.message,
    this.schemaVersion = currentSchemaVersion,
  });

  /// Deserializes from a JSON map, defaulting [schemaVersion] for legacy
  /// payloads.
  factory ErrorResponseDto.fromJson(Map<String, Object?> json) {
    return ErrorResponseDto(
      schemaVersion: (json['schema_version'] as int?) ?? 1,
      code: json['code']! as String,
      message: json['message']! as String,
    );
  }

  /// The current schema version for this DTO.
  static const int currentSchemaVersion = 1;

  /// A stable, machine-readable code (e.g. `auth.token_expired`). Clients may
  /// branch on this; it is part of the contract and does not change meaning.
  final String code;

  /// A human-readable description safe to surface. Never contains secrets.
  final String message;

  /// The schema version of this payload.
  final int schemaVersion;

  /// Serializes to a JSON-encodable map.
  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'code': code,
    'message': message,
  };

  @override
  bool operator ==(Object other) =>
      other is ErrorResponseDto &&
      other.code == code &&
      other.message == message &&
      other.schemaVersion == schemaVersion;

  @override
  int get hashCode => Object.hash(code, message, schemaVersion);
}
