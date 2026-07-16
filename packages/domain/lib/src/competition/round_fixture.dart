import 'package:domain/src/competition/fixture_ref.dart';
import 'package:domain/src/competition/round_id.dart';
import 'package:shared/shared.dart';

/// The many-to-many link between a [Round] and a fixture (Database ADR,
/// Section 3: "the round-fixture table is the M:N link"; Axiom 3).
///
/// This link is the *only* place the Competition context names a fixture. It
/// exists because Football Data owns fixtures with **no** competition awareness
/// (Axiom 3): a single fixture can appear in many rounds across many
/// competitions, so the relationship must live outside both aggregates as an
/// explicit association — never as a `competition_id` column on the fixture.
///
/// It is a member of the Competition aggregate (within the aggregate boundary
/// per Database ADR, Section 3), keyed by its owning [roundId] and the
/// referenced [fixture]. A [displayOrder] fixes the presentation order of
/// fixtures within a round (matchday ordering).
///
/// Pure and immutable; value-comparable by its natural key `(roundId, fixture)`
/// plus order.
final class RoundFixture {
  const RoundFixture._({
    required this.roundId,
    required this.fixture,
    required this.displayOrder,
  });

  /// Rehydrates a link from already-trusted stored fields.
  const RoundFixture.fromStored({
    required this.roundId,
    required this.fixture,
    required this.displayOrder,
  });

  /// Creates a new round↔fixture link from validated inputs. [displayOrder] must
  /// be a non-negative ordinal (0-based position within the round).
  static Result<RoundFixture> create({
    required RoundId roundId,
    required FixtureRef fixture,
    required int displayOrder,
  }) {
    if (displayOrder < 0) {
      return const Result.err(
        AppError.validation(
          'competition.round_fixture_order_invalid',
          'Display order must be a non-negative ordinal',
        ),
      );
    }
    return Result.ok(
      RoundFixture._(
        roundId: roundId,
        fixture: fixture,
        displayOrder: displayOrder,
      ),
    );
  }

  /// The owning round.
  final RoundId roundId;

  /// The referenced fixture (owned by Football Data; referenced by id only).
  final FixtureRef fixture;

  /// The 0-based presentation order of this fixture within its round.
  final int displayOrder;

  @override
  bool operator ==(Object other) =>
      other is RoundFixture &&
      other.roundId == roundId &&
      other.fixture == fixture &&
      other.displayOrder == displayOrder;

  @override
  int get hashCode => Object.hash(roundId, fixture, displayOrder);

  @override
  String toString() =>
      'RoundFixture(round: ${roundId.value}, fixture: ${fixture.value}, '
      'order: $displayOrder)';
}
