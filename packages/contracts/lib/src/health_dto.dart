/// The wire shape of a health-check response.
///
/// [schemaVersion] lets clients and archived payloads evolve safely
/// (API ADR, Section 4).
final class HealthResponseDto {
  /// Creates a health response DTO.
  const HealthResponseDto({
    required this.status,
    required this.databaseReachable,
    this.schemaVersion = currentSchemaVersion,
  });

  /// Deserializes from a JSON map, tolerating older schema versions.
  factory HealthResponseDto.fromJson(Map<String, Object?> json) {
    return HealthResponseDto(
      schemaVersion: (json['schema_version'] as int?) ?? 1,
      status: json['status']! as String,
      databaseReachable: json['database_reachable']! as bool,
    );
  }

  /// The current schema version for this DTO.
  static const int currentSchemaVersion = 1;

  /// `"healthy"` or `"unhealthy"`.
  final String status;

  /// Whether the datastore answered its liveness probe.
  final bool databaseReachable;

  /// The schema version of this payload.
  final int schemaVersion;

  /// Serializes to a JSON-encodable map.
  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'status': status,
    'database_reachable': databaseReachable,
  };

  @override
  bool operator ==(Object other) =>
      other is HealthResponseDto &&
      other.status == status &&
      other.databaseReachable == databaseReachable &&
      other.schemaVersion == schemaVersion;

  @override
  int get hashCode => Object.hash(status, databaseReachable, schemaVersion);
}
