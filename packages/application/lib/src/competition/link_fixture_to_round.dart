import 'package:application/src/competition/ports/competition_repository.dart';
import 'package:application/src/identity/authorization.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// Use-case: link a fixture to a round (Application ADR, Section 2: command
/// intent `LinkFixtureToRound`).
///
/// Establishes the M:N association Competition owns while keeping Football Data
/// decoupled (Axiom 3): the fixture is named by id only ([FixtureRef]), never
/// pulled into the aggregate. Admin-only.
///
/// Business invariant enforced here (second authorization layer): a fixture may
/// only be linked while the round is still [RoundStatus.open]. Once a round is
/// locked its composition is frozen along with its ruleset — adding a fixture to
/// a locked/scored round would change what participants were asked to predict
/// after the fact, so it is rejected as [ErrorKind.invariant].
///
/// Never throws; returns a typed [Result].
final class LinkFixtureToRound {
  /// Creates the use-case over its repository.
  const LinkFixtureToRound(this._repository);

  final CompetitionRepository _repository;

  /// Links [fixtureId] into [roundId] at presentation position [displayOrder].
  Future<Result<RoundFixture>> call({
    required AuthenticatedUser principal,
    required String roundId,
    required String fixtureId,
    required int displayOrder,
  }) async {
    final auth = Authorization.requireRole(principal, PlatformRole.admin);
    if (auth is Err<AuthenticatedUser>) {
      return Result.err(auth.error);
    }

    final roundIdResult = RoundId.tryParse(roundId);
    if (roundIdResult is Err<RoundId>) {
      return Result.err(roundIdResult.error);
    }
    final rId = (roundIdResult as Ok<RoundId>).value;

    final fixtureResult = FixtureRef.tryParse(fixtureId);
    if (fixtureResult is Err<FixtureRef>) {
      return Result.err(fixtureResult.error);
    }

    // The round must exist and still be open.
    final roundResult = await _repository.findRound(rId);
    if (roundResult is Err<Round>) {
      return Result.err(roundResult.error);
    }
    final round = (roundResult as Ok<Round>).value;
    if (!round.status.isOpen) {
      return Result.err(
        AppError.invariant(
          'competition.round_not_open_for_linking',
          'Fixtures can only be linked while the round is open '
              '(round is ${round.status.wireValue})',
        ),
      );
    }

    final linkResult = RoundFixture.create(
      roundId: rId,
      fixture: (fixtureResult as Ok<FixtureRef>).value,
      displayOrder: displayOrder,
    );
    if (linkResult is Err<RoundFixture>) {
      return Result.err(linkResult.error);
    }
    final link = (linkResult as Ok<RoundFixture>).value;

    final saved = await _repository.saveRoundFixture(link);
    return switch (saved) {
      Ok<void>() => Result.ok(link),
      Err<void>(:final error) => Result.err(error),
    };
  }
}
