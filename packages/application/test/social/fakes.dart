import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// A complete in-memory [ReactionRepository] for use-case tests.
///
/// Reproduces the observable contract the Postgres adapter must honour:
/// * `upsertReaction` is idempotent on the natural key `(groupId, roundId,
///   userId)` — a first reaction inserts; the same member reacting again
///   updates in place (never a second row). A scripted conflict proves the
///   `social.reaction_conflict` pivot the use-case resolves by re-reading.
/// * `findReaction` resolves the caller's reaction or `Ok(null)`.
/// * `listReactionsForRound` returns reactedAt-ascending.
/// * `removeReaction` is idempotent (`Ok(false)` when nothing to remove).
/// It never throws; a scripted transient failure proves propagation.
final class InMemoryReactionRepository implements ReactionRepository {
  final List<Reaction> _reactions = [];

  AppError? _scriptedFailure;

  /// If set, the NEXT `upsertReaction` returns this conflict once (simulating a
  /// lost concurrent-react race), then the winning reaction is left in place.
  Reaction? _conflictWinner;

  /// Scripts the *next* call to fail with [error], then clears the script.
  void failNextWith(AppError error) => _scriptedFailure = error;

  /// Scripts the *next* `upsertReaction` to reject with
  /// `social.reaction_conflict`, leaving [winner] as the stored row so the
  /// use-case's re-read finds it.
  void conflictNextUpsertWith(Reaction winner) {
    _conflictWinner = winner;
    _reactions
      ..removeWhere((r) => _sameKey(r, winner))
      ..add(winner);
  }

  AppError? _takeFailure() {
    final f = _scriptedFailure;
    _scriptedFailure = null;
    return f;
  }

  static bool _sameKey(Reaction a, Reaction b) =>
      a.groupId.value == b.groupId.value &&
      a.roundId.value == b.roundId.value &&
      a.userId.value == b.userId.value;

  /// Seeds a reaction directly.
  void seed(Reaction reaction) {
    _reactions
      ..removeWhere((r) => _sameKey(r, reaction))
      ..add(reaction);
  }

  /// Test observability: how many reactions are stored for `(groupId, roundId)`.
  int reactionCount(String groupId, String roundId) => _reactions
      .where((r) => r.groupId.value == groupId && r.roundId.value == roundId)
      .length;

  @override
  Future<Result<void>> upsertReaction(Reaction reaction) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);

    if (_conflictWinner != null && _sameKey(_conflictWinner!, reaction)) {
      _conflictWinner = null;
      return const Result.err(
        AppError.invariant(
          'social.reaction_conflict',
          'A concurrent reaction won the race',
        ),
      );
    }

    _reactions
      ..removeWhere((r) => _sameKey(r, reaction))
      ..add(reaction);
    return const Result.ok(null);
  }

  @override
  Future<Result<Reaction?>> findReaction(
    GroupId groupId,
    RoundId roundId,
    UserId userId,
  ) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    for (final r in _reactions) {
      if (r.groupId.value == groupId.value &&
          r.roundId.value == roundId.value &&
          r.userId.value == userId.value) {
        return Result.ok(r);
      }
    }
    return const Result.ok(null);
  }

  @override
  Future<Result<List<Reaction>>> listReactionsForRound(
    GroupId groupId,
    RoundId roundId,
  ) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    final list =
        _reactions
            .where(
              (r) =>
                  r.groupId.value == groupId.value &&
                  r.roundId.value == roundId.value,
            )
            .toList()
          ..sort((a, b) => a.reactedAt.compareTo(b.reactedAt));
    return Result.ok(List<Reaction>.unmodifiable(list));
  }

  @override
  Future<Result<bool>> removeReaction(
    GroupId groupId,
    RoundId roundId,
    UserId userId,
  ) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    final before = _reactions.length;
    _reactions.removeWhere(
      (r) =>
          r.groupId.value == groupId.value &&
          r.roundId.value == roundId.value &&
          r.userId.value == userId.value,
    );
    return Result.ok(_reactions.length < before);
  }
}

/// A complete in-memory [ActivityFeedReader] for use-case tests.
///
/// Returns the events seeded per `groupId`, newest-first (occurredAt
/// descending), truncated to the requested `limit`. Records the last requested
/// limit so a test can assert the use-case's clamp. Never throws.
final class InMemoryActivityFeedReader implements ActivityFeedReader {
  final Map<String, List<ActivityEvent>> _byGroup = {};

  AppError? _scriptedFailure;

  /// The `limit` the use-case last passed in (for clamp assertions).
  int? lastRequestedLimit;

  /// Scripts the *next* call to fail with [error], then clears the script.
  void failNextWith(AppError error) => _scriptedFailure = error;

  /// Seeds the (unordered) events for a group; they are returned newest-first.
  void seed(String groupId, List<ActivityEvent> events) =>
      _byGroup[groupId] = List<ActivityEvent>.of(events);

  @override
  Future<Result<List<ActivityEvent>>> groupActivityFeed({
    required GroupId groupId,
    required int limit,
  }) async {
    lastRequestedLimit = limit;
    final f = _scriptedFailure;
    _scriptedFailure = null;
    if (f != null) return Result.err(f);
    final all = (_byGroup[groupId.value] ?? const <ActivityEvent>[]).toList()
      ..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
    final capped = all.length > limit ? all.sublist(0, limit) : all;
    return Result.ok(List<ActivityEvent>.unmodifiable(capped));
  }
}

// ---------------------------------------------------------------------------
// Builders shared across the social use-case tests.
// ---------------------------------------------------------------------------

/// Builds an authenticated principal at the given role.
AuthenticatedUser principalUser({
  required String userId,
  PlatformRole role = PlatformRole.user,
}) => AuthenticatedUser(userId: UserId(userId), role: role);

/// Builds a stored group membership (used to seed the group gate).
GroupMembership storedMembership({
  required String id,
  required String groupId,
  required String userId,
  GroupRole role = GroupRole.member,
  DateTime? joinedAt,
}) => GroupMembership.fromStored(
  id: GroupMembershipId(id),
  groupId: GroupId(groupId),
  userId: UserId(userId),
  role: role,
  joinedAt: joinedAt ?? DateTime.utc(2026, 7, 1),
);

/// Builds a stored reaction.
Reaction storedReaction({
  required String id,
  required String groupId,
  required String roundId,
  required String userId,
  ReactionKind emoji = ReactionKind.like,
  DateTime? reactedAt,
}) => Reaction.fromStored(
  id: ReactionId(id),
  groupId: GroupId(groupId),
  roundId: RoundId(roundId),
  userId: UserId(userId),
  emoji: ReactionEmoji.of(emoji),
  reactedAt: reactedAt ?? DateTime.utc(2026, 7, 5, 12),
);

/// A fake [IdGenerator] yielding a scripted sequence of UUIDs.
final class FakeIdGenerator implements IdGenerator {
  FakeIdGenerator(this._ids);

  final List<String> _ids;
  int _i = 0;

  @override
  String newUuid() {
    final id = _ids[_i % _ids.length];
    _i++;
    return id;
  }
}

/// A fake [Clock] returning a fixed UTC instant.
final class FakeClock implements Clock {
  FakeClock([DateTime? now]) : _now = now ?? DateTime.utc(2026, 7, 5, 12);

  final DateTime _now;

  @override
  DateTime nowUtc() => _now;
}
