import 'package:application/src/common/clock.dart';
import 'package:application/src/common/id_generator.dart';
import 'package:application/src/competition/ports/competition_repository.dart';
import 'package:application/src/identity/authorization.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// Use-case: join a competition season, creating a [Participant]
/// (Application ADR, Section 2: command intent `JoinCompetition`).
///
/// Unlike the admin-only lifecycle commands, *any* authenticated user
/// ([PlatformRole.user] and above) may join — this is the social-first entry
/// point (Axiom 1). The principal joins as *themselves*: the participant's
/// `userId` is taken from the verified token, never from the request body, so a
/// caller can never enrol someone else (Security ADR, Section 2).
///
/// Idempotent (Application ADR, Section 2): if the user has already joined the
/// season, the existing [Participant] is returned rather than creating a
/// duplicate or erroring — a retried join converges on one enrolment. The
/// storage-layer unique constraint on `(seasonId, userId)` is the backstop.
///
/// Precondition: the season must exist (invariant error otherwise).
///
/// Never throws; returns a typed [Result].
final class JoinCompetition {
  /// Creates the use-case over its collaborators.
  const JoinCompetition({
    required CompetitionRepository repository,
    required IdGenerator idGenerator,
    required Clock clock,
  }) : _repository = repository,
       _idGenerator = idGenerator,
       _clock = clock;

  final CompetitionRepository _repository;
  final IdGenerator _idGenerator;
  final Clock _clock;

  /// Enrols [principal] into season [seasonId].
  Future<Result<Participant>> call({
    required AuthenticatedUser principal,
    required String seasonId,
  }) async {
    // Any authenticated principal may join; requireRole(user) still rejects a
    // (hypothetical) sub-user authority and keeps the two-layer model explicit.
    final auth = Authorization.requireRole(principal, PlatformRole.user);
    if (auth is Err<AuthenticatedUser>) {
      return Result.err(auth.error);
    }

    final seasonIdResult = SeasonId.tryParse(seasonId);
    if (seasonIdResult is Err<SeasonId>) {
      return Result.err(seasonIdResult.error);
    }
    final sId = (seasonIdResult as Ok<SeasonId>).value;

    // Precondition: the season exists.
    final seasonResult = await _repository.findSeason(sId);
    if (seasonResult is Err<CompetitionSeason>) {
      return Result.err(seasonResult.error);
    }

    // Idempotency: return the existing enrolment if present.
    final existing = await _repository.findParticipant(sId, principal.userId);
    switch (existing) {
      case Ok<Participant?>(:final value):
        if (value != null) {
          return Result.ok(value);
        }
      case Err<Participant?>(:final error):
        return Result.err(error);
    }

    final participantIdResult = ParticipantId.tryParse(_idGenerator.newUuid());
    if (participantIdResult is Err<ParticipantId>) {
      return Result.err(participantIdResult.error);
    }

    final participantResult = Participant.join(
      id: (participantIdResult as Ok<ParticipantId>).value,
      seasonId: sId,
      userId: principal.userId,
      joinedAt: _clock.nowUtc(),
    );
    if (participantResult is Err<Participant>) {
      return Result.err(participantResult.error);
    }
    final participant = (participantResult as Ok<Participant>).value;

    final saved = await _repository.saveParticipant(participant);
    return switch (saved) {
      Ok<void>() => Result.ok(participant),
      // A concurrent join that lost the race surfaces as an invariant
      // conflict from the unique constraint; re-read to converge idempotently.
      Err<void>(:final error) => await _resolveConflict(
        error,
        sId,
        principal.userId,
      ),
    };
  }

  /// On a unique-violation conflict from a concurrent join, re-read the winning
  /// participant so the caller still gets a successful, idempotent result. Any
  /// other error is propagated unchanged.
  Future<Result<Participant>> _resolveConflict(
    AppError error,
    SeasonId seasonId,
    UserId userId,
  ) async {
    if (error.code != 'competition.already_joined') {
      return Result.err(error);
    }
    final reread = await _repository.findParticipant(seasonId, userId);
    return switch (reread) {
      Ok<Participant?>(:final value) =>
        value != null ? Result.ok(value) : Result.err(error),
      Err<Participant?>(:final error) => Result.err(error),
    };
  }
}
