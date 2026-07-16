import 'package:application/application.dart';
import 'package:uuid/uuid.dart';

/// [IdGenerator] backed by the `uuid` package's cryptographically-strong v4
/// generator.
///
/// API verified against `uuid` 4.5.3 on pub.dev (2026-07-09): `Uuid().v4()`
/// returns a canonical hyphenated (8-4-4-4-12) RFC-4122 v4 string, exactly the
/// shape the typed id `tryParse` methods accept, using a cryptographically
/// strong RNG on all platforms.
final class UuidIdGenerator implements IdGenerator {
  /// Creates a generator over an internal [Uuid] instance.
  UuidIdGenerator() : _uuid = const Uuid();

  final Uuid _uuid;

  @override
  String newUuid() => _uuid.v4();
}
