import 'package:application/src/competition/ports/competition_repository.dart';
import 'package:application/src/identity/authorization.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// Use-case: lock an open [Round] once its prediction window closes
/// (Application ADR, Section 2: command intent `LockRound`).
///
/// Transitions the round `open → locked` via the domain's lifecycle machine
/// (`Round.transitionTo`, the single definition of legal edges), then persists
/// with an *optimistic-concurrency guard*: the repository update is keyed on the
/// expected prior status, so two concurrent locks cannot both succeed and a
/// stale attempt is reported as [ErrorKind.invariant]
/// `competition.round_transition_conflict`.
///
/// Locking never touches the frozen ruleset — the snapshot is carried through
/// unchanged, upholding the freeze invariant. Admin-only.
///
/// Never throws; returns a typed [Result].
final class LockRound {
  /// Creates the use-case over its repository.
  const LockRound(this._repository);

  final CompetitionRepository _repository;

  /// Locks the round identified by [roundId].
  Future<Result<Round>> call({
    required AuthenticatedUser principal,
    required String roundId,
  }) async {
    final auth = Authorization.requireRole(principal, PlatformRole.admin);
    if (auth is Err<AuthenticatedUser>) {
      return Result.err(auth.error);
    }

    final roundIdResult = RoundId.tryParse(roundId);
    if (roundIdResult is Err<RoundId>) {
      return Result.err(roundIdResult.error);
    }

    final roundResult = await _repository.findRound(
      (roundIdResult as Ok<RoundId>).value,
    );
    if (roundResult is Err<Round>) {
      return Result.err(roundResult.error);
    }
    final round = (roundResult as Ok<Round>).value;
    final priorStatus = round.status;

    final transitioned = round.transitionTo(RoundStatus.locked);
    if (transitioned is Err<Round>) {
      return Result.err(transitioned.error);
    }
    final locked = (transitioned as Ok<Round>).value;

    final saved = await _repository.updateRoundStatus(locked, priorStatus);
    return switch (saved) {
      Ok<void>() => Result.ok(locked),
      Err<void>(:final error) => Result.err(error),
    };
  }
}
