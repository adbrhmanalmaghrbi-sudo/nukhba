import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// A complete in-memory [AuditLogRepository] for use-case tests.
///
/// Reproduces the observable contract the Postgres adapter must honour:
/// * `append` stores one immutable row and returns it; append-only (no
///   update/delete surface).
/// * `list` returns rows newest-first (occurredAt desc, id desc) truncated to
///   `limit`, and records the last requested limit so a test can assert the
///   use-case's clamp.
/// It never throws; a scripted transient failure proves propagation.
final class InMemoryAuditLogRepository implements AuditLogRepository {
  final List<AuditEntry> rows = [];

  AppError? _scriptedFailure;

  /// The `limit` the use-case last passed to [list].
  int? lastRequestedLimit;

  /// Scripts the *next* call to fail with [error], then clears the script.
  void failNextWith(AppError error) => _scriptedFailure = error;

  AppError? _takeFailure() {
    final f = _scriptedFailure;
    _scriptedFailure = null;
    return f;
  }

  @override
  Future<Result<AuditEntry>> append(AuditEntry entry) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    rows.add(entry);
    return Result.ok(entry);
  }

  @override
  Future<Result<List<AuditEntry>>> list({required int limit}) async {
    lastRequestedLimit = limit;
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    final sorted = [...rows]
      ..sort((a, b) {
        final byTime = b.occurredAt.compareTo(a.occurredAt);
        if (byTime != 0) return byTime;
        return b.id.value.compareTo(a.id.value);
      });
    final capped = sorted.length > limit ? sorted.sublist(0, limit) : sorted;
    return Result.ok(List<AuditEntry>.unmodifiable(capped));
  }
}

/// A complete in-memory [UserAdminRepository] for use-case tests.
///
/// * `findUserById` resolves a seeded user or `Ok(null)`.
/// * `updateUser` replaces the stored row by id and returns the stored value.
/// It never throws; a scripted transient failure proves propagation.
final class InMemoryUserAdminRepository implements UserAdminRepository {
  final Map<String, User> _byId = {};

  AppError? _scriptedFailure;

  void failNextWith(AppError error) => _scriptedFailure = error;

  AppError? _takeFailure() {
    final f = _scriptedFailure;
    _scriptedFailure = null;
    return f;
  }

  /// Seeds a stored user.
  void seed(User user) => _byId[user.id.value] = user;

  /// Test observability: the current stored value for [id].
  User? rowOf(String id) => _byId[id];

  @override
  Future<Result<User?>> findUserById(UserId id) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    return Result.ok(_byId[id.value]);
  }

  @override
  Future<Result<User>> updateUser(User user) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    _byId[user.id.value] = user;
    return Result.ok(user);
  }
}

/// A minimal in-memory [ParticipantReader] (mirrors the ledger fake) for the
/// admin support-read use-case.
final class InMemoryParticipantReader implements ParticipantReader {
  final Map<String, Participant> _byId = {};

  AppError? _scriptedFailure;

  void failNextWith(AppError error) => _scriptedFailure = error;

  AppError? _takeFailure() {
    final f = _scriptedFailure;
    _scriptedFailure = null;
    return f;
  }

  void seed(Participant participant) =>
      _byId[participant.id.value] = participant;

  @override
  Future<Result<Participant?>> findParticipantById(ParticipantId id) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    return Result.ok(_byId[id.value]);
  }
}

/// A minimal in-memory [LedgerRepository] serving only the reads the admin
/// support-view use-case needs (`listEntries`); the append/balance paths are
/// not exercised here and return empty/zero.
final class InMemoryLedgerReadRepository implements LedgerRepository {
  final Map<String, List<PointEntry>> _byParticipant = {};

  AppError? _scriptedFailure;

  void failNextWith(AppError error) => _scriptedFailure = error;

  AppError? _takeFailure() {
    final f = _scriptedFailure;
    _scriptedFailure = null;
    return f;
  }

  void seed(String participantId, List<PointEntry> entries) =>
      _byParticipant[participantId] = entries;

  @override
  Future<Result<List<PointEntry>>> appendEntries(
    List<PointEntry> entries,
  ) async => Result.ok(List<PointEntry>.unmodifiable(entries));

  @override
  Future<Result<List<PointEntry>>> listEntries(
    ParticipantId participantId,
  ) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    return Result.ok(
      List<PointEntry>.unmodifiable(_byParticipant[participantId.value] ?? []),
    );
  }

  @override
  Future<Result<LedgerBalance>> balanceFor(ParticipantId participantId) async =>
      // Not exercised by the admin support-view use-case (it reads the entry
      // stream, not the balance); the domain projection keeps the fake honest.
      LedgerBalance.project(
        participantId: participantId,
        entries: _byParticipant[participantId.value] ?? const [],
      );
}

// ---------------------------------------------------------------------------
// Shared builders.
// ---------------------------------------------------------------------------

/// Builds an authenticated principal at the given role.
AuthenticatedUser principal({
  required String userId,
  PlatformRole role = PlatformRole.admin,
}) => AuthenticatedUser(userId: UserId(userId), role: role);

/// Builds a stored user.
User storedUser({
  required String id,
  PlatformRole role = PlatformRole.user,
  UserStatus status = UserStatus.active,
  String? email = 'human@example.com',
}) => User(id: UserId(id), email: email, role: role, status: status);

/// Builds a stored active participant.
Participant storedParticipant({
  required String id,
  required String seasonId,
  required String userId,
}) => Participant.fromStored(
  id: ParticipantId(id),
  seasonId: SeasonId(seasonId),
  userId: UserId(userId),
  status: ParticipantStatus.active,
  joinedAt: DateTime.utc(2026, 7, 1, 12),
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
  FakeClock([DateTime? now]) : _now = now ?? DateTime.utc(2026, 7, 13, 12);

  final DateTime _now;

  @override
  DateTime nowUtc() => _now;
}

/// Builds an [AuditRecorder] over an [InMemoryAuditLogRepository] + fakes.
AuditRecorder auditRecorderOver(
  InMemoryAuditLogRepository auditLog, {
  List<String>? ids,
  DateTime? now,
}) => AuditRecorder(
  auditLog: auditLog,
  idGenerator: FakeIdGenerator(ids ?? const [auditUuid]),
  clock: FakeClock(now),
);

// Canonical UUIDs handy for tests.
const adminUuid = '11111111-1111-4111-8111-111111111111';
const targetUuid = '22222222-2222-4222-8222-222222222222';
const participantUuid = '33333333-3333-4333-8333-333333333333';
const seasonUuid = '44444444-4444-4444-8444-444444444444';
const auditUuid = '55555555-5555-4555-8555-555555555555';
const auditUuid2 = '66666666-6666-4666-8666-666666666666';
