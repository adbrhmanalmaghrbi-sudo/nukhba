/// Port for generating fresh, unique identifiers for server-created aggregates
/// (Application ADR, Section 9: side-effecting concerns are ports, implemented
/// in Infrastructure).
///
/// The domain must never perform IO or non-determinism (Coding Standards ADR,
/// Section 1), so id *generation* — which is non-deterministic — lives behind
/// this port rather than inside an entity. A use-case obtains a raw id string
/// here, then wraps it in the appropriate typed [EntityId] via that id's
/// `tryParse`, keeping id creation total and testable (a fake can yield fixed
/// ids).
///
/// Contract for implementations:
/// * MUST return a canonical UUID string (8-4-4-4-12, hyphenated) so the typed
///   id `tryParse` accepts it.
/// * MUST be collision-free for practical purposes (UUID v4 or better).
/// * MUST NOT throw.
abstract interface class IdGenerator {
  /// Returns a fresh canonical UUID string.
  String newUuid();
}
