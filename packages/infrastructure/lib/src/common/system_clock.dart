import 'package:application/application.dart';

/// [Clock] backed by the system wall clock, always yielding UTC.
///
/// `DateTime.now().toUtc()` guarantees `isUtc == true`, satisfying the port's
/// contract that every domain timestamp is produced in a single unambiguous
/// zone (Application ADR, Section 9).
final class SystemClock implements Clock {
  /// Creates a system clock.
  const SystemClock();

  @override
  DateTime nowUtc() => DateTime.now().toUtc();
}
