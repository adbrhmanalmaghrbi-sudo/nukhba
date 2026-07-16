import 'package:application/src/competition/ports/competition_repository.dart';
import 'package:application/src/identity/authorization.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// Query use-case: list the competitions a client may browse (Application ADR,
/// Section 2: query separated from command).
///
/// This is the read half the Competition-browse client scope needs: the
/// write-side `CreateCompetition` command has always existed, but there was no
/// way for a client to *discover* the competitions it could join. Added under
/// BLOCKER FA-1 (2026-07-13) as a strictly additive read over the already-
/// migrated `competition.*` tables — no new domain rule, no side effect.
///
/// Visibility: the repository returns only *public* competitions (the
/// discoverable catalogue, mirroring the migration's `competitions_select_public`
/// RLS backstop). The caller must be an authenticated user (a signed-in member
/// browses the catalogue); the gate is `PlatformRole.user`, matching every
/// other client-facing read (e.g. `GetRoundScores`). An empty catalogue is a
/// legitimate empty list, never an error.
///
/// Never throws; returns a typed [Result].
final class ListCompetitions {
  /// Creates the use-case over its repository.
  const ListCompetitions({required CompetitionRepository repository})
    : _competition = repository;

  final CompetitionRepository _competition;

  /// Lists the browsable competitions visible to [principal].
  Future<Result<List<Competition>>> call({
    required AuthenticatedUser principal,
  }) async {
    final auth = Authorization.requireRole(principal, PlatformRole.user);
    if (auth is Err<AuthenticatedUser>) {
      return Result.err(auth.error);
    }

    return _competition.listCompetitions();
  }
}
