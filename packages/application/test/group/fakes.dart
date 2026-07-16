import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// A complete in-memory [GroupRepository] for use-case tests.
///
/// Reproduces the observable contract the Postgres adapter must honour:
/// * `createGroupWithOwner` stores group + owner membership atomically; a
///   duplicate group id or invite code surfaces `group.invite_code_conflict`.
/// * `saveMembership` enforces `(groupId, userId)` uniqueness, surfacing
///   `group.already_member` (the code `JoinGroupByInvite` pivots on).
/// * `findByInviteCode` resolves the *current* code only (a rotated code no
///   longer resolves — mirrors the live-code semantics).
/// * `listMemberships` returns joinedAt-ascending (owner first).
/// It never throws; a scripted transient failure proves propagation.
final class InMemoryGroupRepository implements GroupRepository {
  final Map<String, Group> _groups = {};
  final List<GroupMembership> _memberships = [];

  AppError? _scriptedFailure;

  /// Scripts the *next* call to fail with [error], then clears the script.
  void failNextWith(AppError error) => _scriptedFailure = error;

  AppError? _takeFailure() {
    final f = _scriptedFailure;
    _scriptedFailure = null;
    return f;
  }

  /// Seeds a group directly (tests that need a pre-existing group).
  void seedGroup(Group group) => _groups[group.id.value] = group;

  /// Seeds a membership directly.
  void seedMembership(GroupMembership membership) =>
      _memberships.add(membership);

  /// Test observability: how many memberships are stored for [groupId].
  int membershipCount(String groupId) =>
      _memberships.where((m) => m.groupId.value == groupId).length;

  @override
  Future<Result<void>> createGroupWithOwner(
    Group group,
    GroupMembership ownerMembership,
  ) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    if (_groups.containsKey(group.id.value) ||
        _groups.values.any(
          (g) => g.inviteCode.value == group.inviteCode.value,
        )) {
      return const Result.err(
        AppError.invariant(
          'group.invite_code_conflict',
          'A group with that id or invite code already exists',
        ),
      );
    }
    _groups[group.id.value] = group;
    _memberships.add(ownerMembership);
    return const Result.ok(null);
  }

  @override
  Future<Result<Group?>> findGroup(GroupId id) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    return Result.ok(_groups[id.value]);
  }

  @override
  Future<Result<Group?>> findByInviteCode(InviteCode inviteCode) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    for (final g in _groups.values) {
      if (g.inviteCode.value == inviteCode.value) {
        return Result.ok(g);
      }
    }
    return const Result.ok(null);
  }

  @override
  Future<Result<void>> updateGroup(Group group) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    // A rotated invite code colliding with another live group's code.
    final collision = _groups.values.any(
      (g) =>
          g.id.value != group.id.value &&
          g.inviteCode.value == group.inviteCode.value,
    );
    if (collision) {
      return const Result.err(
        AppError.invariant(
          'group.invite_code_conflict',
          'That invite code collides with another group',
        ),
      );
    }
    _groups[group.id.value] = group;
    return const Result.ok(null);
  }

  @override
  Future<Result<void>> saveMembership(GroupMembership membership) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    final dup = _memberships.any(
      (m) =>
          m.groupId.value == membership.groupId.value &&
          m.userId.value == membership.userId.value,
    );
    if (dup) {
      return const Result.err(
        AppError.invariant(
          'group.already_member',
          'The user is already a member of the group',
        ),
      );
    }
    _memberships.add(membership);
    return const Result.ok(null);
  }

  @override
  Future<Result<GroupMembership?>> findMembership(
    GroupId groupId,
    UserId userId,
  ) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    for (final m in _memberships) {
      if (m.groupId.value == groupId.value && m.userId.value == userId.value) {
        return Result.ok(m);
      }
    }
    return const Result.ok(null);
  }

  @override
  Future<Result<List<GroupMembership>>> listMemberships(GroupId groupId) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    final list =
        _memberships.where((m) => m.groupId.value == groupId.value).toList()
          ..sort((a, b) => a.joinedAt.compareTo(b.joinedAt));
    return Result.ok(List<GroupMembership>.unmodifiable(list));
  }
}

/// A complete in-memory [GroupStandingsReader] for use-case tests.
///
/// Returns the unranked group∩season standing entries (member userId + unranked
/// season entry) seeded per `(groupId, seasonId)`. The list order is
/// unspecified (the use-case ranks it). Never throws.
final class InMemoryGroupStandingsReader implements GroupStandingsReader {
  final Map<String, List<GroupStandingEntry>> _byKey = {};

  AppError? _scriptedFailure;

  /// Scripts the *next* call to fail with [error], then clears the script.
  void failNextWith(AppError error) => _scriptedFailure = error;

  static String _key(String groupId, String seasonId) => '$groupId::$seasonId';

  /// Seeds the unranked standing entries for a `(group, season)` pair.
  void seed(
    String groupId,
    String seasonId,
    List<GroupStandingEntry> entries,
  ) => _byKey[_key(groupId, seasonId)] = List<GroupStandingEntry>.of(entries);

  @override
  Future<Result<List<GroupStandingEntry>>> groupSeasonStandings({
    required GroupId groupId,
    required SeasonId seasonId,
  }) async {
    final f = _scriptedFailure;
    _scriptedFailure = null;
    if (f != null) return Result.err(f);
    return Result.ok(
      List<GroupStandingEntry>.unmodifiable(
        _byKey[_key(groupId.value, seasonId.value)] ?? const [],
      ),
    );
  }
}

/// A fake [IdGenerator] yielding a scripted sequence of UUIDs (so a test can
/// pin the group id, then the owner-membership id, deterministically).
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
  FakeClock([DateTime? now]) : _now = now ?? DateTime.utc(2026, 7, 11, 12);

  final DateTime _now;

  @override
  DateTime nowUtc() => _now;
}

/// A fake [InviteCodeGenerator] yielding a scripted sequence of well-formed
/// codes (each exactly `InviteCode.codeLength` chars over the alphabet).
final class FakeInviteCodeGenerator implements InviteCodeGenerator {
  FakeInviteCodeGenerator(this._codes);

  final List<String> _codes;
  int _i = 0;

  @override
  InviteCode newCode() {
    final raw = _codes[_i % _codes.length];
    _i++;
    return (InviteCode.tryParse(raw) as Ok<InviteCode>).value;
  }
}

// ---------------------------------------------------------------------------
// Builders shared across the group use-case tests.
// ---------------------------------------------------------------------------

/// Builds an authenticated principal at the given role.
AuthenticatedUser principalUser({
  required String userId,
  PlatformRole role = PlatformRole.user,
}) => AuthenticatedUser(userId: UserId(userId), role: role);

/// A well-formed invite code (10 chars over the alphabet).
const String sampleCode = 'ABCDEFGHJK';
const String otherCode = 'MNPQRSTUVW';

/// Builds a stored group.
Group storedGroup({
  required String id,
  required String ownerId,
  String name = 'The Circle',
  String inviteCode = sampleCode,
  DateTime? createdAt,
}) => Group.fromStored(
  id: GroupId(id),
  ownerId: UserId(ownerId),
  name: name,
  inviteCode: (InviteCode.tryParse(inviteCode) as Ok<InviteCode>).value,
  createdAt: createdAt ?? DateTime.utc(2026, 7, 1),
);

/// Builds a stored membership.
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

/// Builds an unranked group standing entry (member userId + season projection).
GroupStandingEntry standing({
  required String userId,
  required String participantId,
  required int totalPoints,
  int entryCount = 1,
  DateTime? joinedAt,
}) => GroupStandingEntry(
  userId: UserId(userId),
  entry:
      (LeaderboardEntry.projected(
                participantId: ParticipantId(participantId),
                totalPoints: totalPoints,
                entryCount: entryCount,
                joinedAt: joinedAt ?? DateTime.utc(2026, 7, 1, 9),
              )
              as Ok<LeaderboardEntry>)
          .value,
);
