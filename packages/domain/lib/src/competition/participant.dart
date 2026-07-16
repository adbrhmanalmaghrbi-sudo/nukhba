import 'package:domain/src/competition/participant_id.dart';
import 'package:domain/src/competition/participant_status.dart';
import 'package:domain/src/competition/season_id.dart';
import 'package:domain/src/identity/user_id.dart';
import 'package:shared/shared.dart';

/// A user's enrolment in a [CompetitionSeason] — its own aggregate root,
/// deliberately separate from Competition (Database ADR, Section 1: "Participant
/// and Prediction are separate aggregates from Competition … millions of
/// predictions must not require locking the competition aggregate").
///
/// A participant is the join point between an [Identity] `User` and a season: a
/// [Prediction] (later phase) references exactly one participant, and a
/// `PointEntry` in the Ledger references the participant + season. Withdrawal
/// never deletes the row — the competitive record is an asset (Axiom 5), and
/// ledger entries pin the participant in place (Database ADR: restriction over
/// cascade for Tier-1 data).
///
/// Pure and immutable; state changes produce new values.
final class Participant {
  const Participant._({
    required this.id,
    required this.seasonId,
    required this.userId,
    required this.status,
    required this.joinedAt,
  });

  /// Rehydrates a participant from already-trusted stored fields.
  const Participant.fromStored({
    required this.id,
    required this.seasonId,
    required this.userId,
    required this.status,
    required this.joinedAt,
  });

  /// Enrols a user into a season as a new, [ParticipantStatus.active]
  /// participant.
  ///
  /// [joinedAt] must be a UTC instant (callers normalize) so audit ordering is
  /// unambiguous. Uniqueness of `(seasonId, userId)` — a user joins a season at
  /// most once — is enforced structurally in the schema and by the join
  /// use-case; it is not re-checked here because the entity cannot see other
  /// participants (an aggregate reasons only about itself).
  static Result<Participant> join({
    required ParticipantId id,
    required SeasonId seasonId,
    required UserId userId,
    required DateTime joinedAt,
  }) {
    if (!joinedAt.isUtc) {
      return const Result.err(
        AppError.validation(
          'competition.participant_joined_at_not_utc',
          'joinedAt must be provided in UTC',
        ),
      );
    }
    return Result.ok(
      Participant._(
        id: id,
        seasonId: seasonId,
        userId: userId,
        status: ParticipantStatus.active,
        joinedAt: joinedAt,
      ),
    );
  }

  /// The participant identity.
  final ParticipantId id;

  /// The season this enrolment belongs to.
  final SeasonId seasonId;

  /// The enrolled platform user.
  final UserId userId;

  /// The current enrolment status.
  final ParticipantStatus status;

  /// When the user joined the season (UTC).
  final DateTime joinedAt;

  /// Returns a withdrawn copy of this participant.
  ///
  /// Idempotent-friendly: withdrawing an already-withdrawn participant is an
  /// [ErrorKind.invariant] failure so the use-case can report it distinctly,
  /// rather than silently reasserting the same state.
  Result<Participant> withdraw() {
    if (status == ParticipantStatus.withdrawn) {
      return const Result.err(
        AppError.invariant(
          'competition.participant_already_withdrawn',
          'Participant has already withdrawn from the season',
        ),
      );
    }
    return Result.ok(
      Participant._(
        id: id,
        seasonId: seasonId,
        userId: userId,
        status: ParticipantStatus.withdrawn,
        joinedAt: joinedAt,
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Participant &&
      other.id == id &&
      other.seasonId == seasonId &&
      other.userId == userId &&
      other.status == status &&
      other.joinedAt == joinedAt;

  @override
  int get hashCode => Object.hash(id, seasonId, userId, status, joinedAt);

  @override
  String toString() =>
      'Participant(${id.value}, season: ${seasonId.value}, '
      'user: ${userId.value}, ${status.wireValue})';
}
