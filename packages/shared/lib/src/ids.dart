/// A strongly-typed identifier base, preventing raw-string id mixing
/// (Coding Standards ADR, Section 2: value objects, not primitives).
///
/// Concrete id types (UserId, GroupId, ...) will extend this in later phases.
abstract base class EntityId {
  /// Creates an id from its canonical string form.
  const EntityId(this.value);

  /// The canonical string representation (UUID in later phases).
  final String value;

  @override
  bool operator ==(Object other) =>
      other.runtimeType == runtimeType &&
      other is EntityId &&
      other.value == value;

  @override
  int get hashCode => Object.hash(runtimeType, value);

  @override
  String toString() => '$runtimeType($value)';
}
