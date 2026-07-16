/// Port for reading the current instant (Application ADR, Section 9).
///
/// Reading wall-clock time is non-deterministic IO, which the domain forbids
/// (Coding Standards ADR, Section 1). Use-cases that need "now" — e.g. stamping
/// a participant's `joinedAt` — depend on this port so tests inject a fixed
/// instant and assert exact timestamps.
///
/// Contract for implementations:
/// * [nowUtc] MUST return an instant in UTC (`DateTime.isUtc == true`) so all
///   domain timestamps are stored and compared in a single, unambiguous zone.
/// * MUST NOT throw.
abstract interface class Clock {
  /// The current instant, in UTC.
  DateTime nowUtc();
}
