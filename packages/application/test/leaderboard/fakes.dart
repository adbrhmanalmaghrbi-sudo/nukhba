import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// A complete in-memory [LeaderboardRepository] for use-case tests.
///
/// Reproduces the observable contract the Postgres adapter must honour: it
/// returns the **unranked** projection entries for a season (one per
/// participant, each carrying a signed total, movement count, and joinedAt
/// tie-break key), in an unspecified order (the use-case sorts + ranks). It
/// never throws; a scripted transient failure proves propagation.
final class FakeLeaderboardRepository implements LeaderboardRepository {
  final Map<String, List<LeaderboardEntry>> _bySeason = {};

  AppError? _scriptedFailure;

  /// Scripts the *next* call to fail with [error], then clears the script.
  void failNextWith(AppError error) => _scriptedFailure = error;

  AppError? _takeFailure() {
    final f = _scriptedFailure;
    _scriptedFailure = null;
    return f;
  }

  /// Seeds the unranked projection for a season (tests arrange state directly).
  void seed(String seasonId, List<LeaderboardEntry> entries) =>
      _bySeason[seasonId] = List<LeaderboardEntry>.of(entries);

  @override
  Future<Result<List<LeaderboardEntry>>> seasonStandings(
    SeasonId seasonId,
  ) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    return Result.ok(
      List<LeaderboardEntry>.unmodifiable(
        _bySeason[seasonId.value] ?? const [],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Builders shared across the leaderboard use-case tests.
// ---------------------------------------------------------------------------

/// Builds an unranked projection entry (as the adapter would produce it).
LeaderboardEntry boardEntry({
  required String participantId,
  required int totalPoints,
  int entryCount = 1,
  DateTime? joinedAt,
}) =>
    (LeaderboardEntry.projected(
              participantId: ParticipantId(participantId),
              totalPoints: totalPoints,
              entryCount: entryCount,
              joinedAt: joinedAt ?? DateTime.utc(2026, 7, 1, 9),
            )
            as Ok<LeaderboardEntry>)
        .value;

/// Builds a stored active participant of [seasonId] owned by [userId].
Participant boardParticipant({
  required String id,
  required String seasonId,
  required String userId,
  ParticipantStatus status = ParticipantStatus.active,
}) => Participant.fromStored(
  id: ParticipantId(id),
  seasonId: SeasonId(seasonId),
  userId: UserId(userId),
  status: status,
  joinedAt: DateTime.utc(2026),
);

/// Builds an authenticated principal at the given role.
AuthenticatedUser principalUser({
  required String userId,
  PlatformRole role = PlatformRole.user,
}) => AuthenticatedUser(userId: UserId(userId), role: role);
