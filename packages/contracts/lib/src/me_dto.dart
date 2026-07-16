/// The wire shape of the authenticated principal returned by the identity
/// endpoint (API ADR, Section 4: DTOs are decoupled from the schema and carry a
/// schema version so client and archived payloads evolve safely).
///
/// This is a pure data shape shared verbatim by client and server; it depends
/// on nothing (Application ADR, Section 3). It intentionally excludes anything
/// sensitive or token-internal (no raw JWT, no signature material) — only the
/// stable identity facts a caller needs about itself.
final class AuthenticatedUserDto {
  /// Creates an authenticated-user DTO.
  const AuthenticatedUserDto({
    required this.userId,
    required this.role,
    required this.status,
    this.email,
  });

  /// Deserializes from a JSON map, tolerating older schema versions by reading
  /// only known keys.
  factory AuthenticatedUserDto.fromJson(Map<String, Object?> json) {
    return AuthenticatedUserDto(
      userId: json['user_id']! as String,
      role: json['role']! as String,
      status: json['status']! as String,
      email: json['email'] as String?,
    );
  }

  /// The platform user id (UUID string).
  final String userId;

  /// The platform role name (`user` / `admin` / `service`).
  final String role;

  /// The account status name (`active` / `suspended`).
  final String status;

  /// The user's email, when known.
  final String? email;

  /// Serializes to a JSON-encodable map.
  Map<String, Object?> toJson() => {
    'user_id': userId,
    'role': role,
    'status': status,
    'email': email,
  };

  @override
  bool operator ==(Object other) =>
      other is AuthenticatedUserDto &&
      other.userId == userId &&
      other.role == role &&
      other.status == status &&
      other.email == email;

  @override
  int get hashCode => Object.hash(userId, role, status, email);
}

/// The response body of `GET /me`: the current principal plus a schema version
/// (API ADR, Section 4).
final class MeResponseDto {
  /// Creates a `/me` response DTO.
  const MeResponseDto({
    required this.user,
    this.schemaVersion = currentSchemaVersion,
  });

  /// Deserializes from a JSON map, defaulting [schemaVersion] for legacy
  /// payloads that predate the field.
  factory MeResponseDto.fromJson(Map<String, Object?> json) {
    final user = (json['user']! as Map<Object?, Object?>)
        .cast<String, Object?>();
    return MeResponseDto(
      schemaVersion: (json['schema_version'] as int?) ?? 1,
      user: AuthenticatedUserDto.fromJson(user),
    );
  }

  /// The current schema version for this DTO.
  static const int currentSchemaVersion = 1;

  /// The authenticated principal.
  final AuthenticatedUserDto user;

  /// The schema version of this payload.
  final int schemaVersion;

  /// Serializes to a JSON-encodable map.
  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'user': user.toJson(),
  };

  @override
  bool operator ==(Object other) =>
      other is MeResponseDto &&
      other.user == user &&
      other.schemaVersion == schemaVersion;

  @override
  int get hashCode => Object.hash(user, schemaVersion);
}
