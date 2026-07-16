import 'package:shared/shared.dart';

/// A *reference* to a fixture owned by the Football Data context, used by the
/// Competition aggregate's `RoundFixture` link.
///
/// This is deliberately only an id, not the `Fixture` entity: Axiom 3 keeps
/// Football Data decoupled — a `Fixture` carries **no** competition awareness,
/// and the same fixture may appear in many rounds across many competitions
/// (Database ADR, Section 3: "the fixture table carries no competition
/// reference"). The full `Fixture` aggregate is built in the Football Data
/// phase; Competition only needs to name the fixture it links, so we model that
/// crossing-of-contexts as a typed id reference rather than reaching into the
/// other aggregate.
///
/// A value object (Coding Standards ADR, Section 2), canonically a UUID.
final class FixtureRef extends EntityId {
  /// Creates a [FixtureRef] from its canonical UUID string.
  const FixtureRef(super.value);

  /// Parses a [FixtureRef] from an untrusted [raw] string, returning a
  /// validation [AppError] when it is absent or not a canonical UUID.
  static Result<FixtureRef> tryParse(String? raw) {
    if (raw == null || raw.isEmpty) {
      return const Result.err(
        AppError.validation(
          'competition.fixture_ref_empty',
          'Fixture id is required',
        ),
      );
    }
    if (!_uuid.hasMatch(raw)) {
      return const Result.err(
        AppError.validation(
          'competition.fixture_ref_malformed',
          'Fixture id must be a UUID',
        ),
      );
    }
    return Result.ok(FixtureRef(raw));
  }

  static final RegExp _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
    r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );
}
