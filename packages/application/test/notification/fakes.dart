import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// A complete in-memory [NotificationRepository] for use-case tests.
///
/// Reproduces the observable contract the Postgres adapter must honour:
/// * `createIfAbsent` is idempotent on the dedupe key
///   `(recipientId, kind, subjectRef)` — a first create inserts and returns
///   `Ok(true)`; an identical replay is a no-op returning `Ok(false)`.
/// * `listForRecipient` returns the recipient's rows newest-first (createdAt
///   desc, id desc), truncated to `limit`; records the last requested limit so
///   a test can assert the use-case's clamp.
/// * `findForRecipient` resolves a recipient-owned row or `Ok(null)` (foreign
///   or absent both `Ok(null)` — no existence oracle).
/// * `markRead` is recipient-scoped + idempotent: `Ok(true)` on unread→read,
///   `Ok(false)` when already read, `Ok(null)` when foreign/absent.
/// * `unreadCount` counts the recipient's unread rows.
/// It never throws; a scripted transient failure proves propagation.
final class InMemoryNotificationRepository implements NotificationRepository {
  final List<Notification> _rows = [];

  AppError? _scriptedFailure;

  /// The `limit` the use-case last passed to [listForRecipient].
  int? lastRequestedLimit;

  /// Scripts the *next* call to fail with [error], then clears the script.
  void failNextWith(AppError error) => _scriptedFailure = error;

  AppError? _takeFailure() {
    final f = _scriptedFailure;
    _scriptedFailure = null;
    return f;
  }

  static bool _sameDedupe(Notification a, Notification b) =>
      a.recipientId.value == b.recipientId.value &&
      a.kind == b.kind &&
      a.subject.dedupeRef == b.subject.dedupeRef;

  /// Seeds a notification directly (bypassing the dedupe skip).
  void seed(Notification notification) => _rows.add(notification);

  /// Test observability: how many rows exist for [recipientId].
  int countFor(String recipientId) =>
      _rows.where((n) => n.recipientId.value == recipientId).length;

  /// Test observability: the current stored value of [id], or null.
  Notification? rowOf(String id) {
    for (final n in _rows) {
      if (n.id.value == id) return n;
    }
    return null;
  }

  @override
  Future<Result<bool>> createIfAbsent(Notification notification) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    final exists = _rows.any((n) => _sameDedupe(n, notification));
    if (exists) {
      return const Result.ok(false);
    }
    _rows.add(notification);
    return const Result.ok(true);
  }

  @override
  Future<Result<List<Notification>>> listForRecipient(
    UserId recipientId, {
    required int limit,
  }) async {
    lastRequestedLimit = limit;
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    final mine =
        _rows.where((n) => n.recipientId.value == recipientId.value).toList()
          ..sort((a, b) {
            final byCreated = b.createdAt.compareTo(a.createdAt);
            if (byCreated != 0) return byCreated;
            return b.id.value.compareTo(a.id.value);
          });
    final capped = mine.length > limit ? mine.sublist(0, limit) : mine;
    return Result.ok(List<Notification>.unmodifiable(capped));
  }

  @override
  Future<Result<Notification?>> findForRecipient(
    NotificationId id,
    UserId recipientId,
  ) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    for (final n in _rows) {
      if (n.id.value == id.value && n.recipientId.value == recipientId.value) {
        return Result.ok(n);
      }
    }
    return const Result.ok(null);
  }

  @override
  Future<Result<bool?>> markRead(
    NotificationId id,
    UserId recipientId,
    DateTime readAt,
  ) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    for (var i = 0; i < _rows.length; i++) {
      final n = _rows[i];
      if (n.id.value == id.value && n.recipientId.value == recipientId.value) {
        if (n.isRead) {
          return const Result.ok(false);
        }
        final marked = n.markRead(readAt);
        if (marked is Err<Notification>) {
          return Result.err(marked.error);
        }
        _rows[i] = (marked as Ok<Notification>).value;
        return const Result.ok(true);
      }
    }
    // Foreign or absent — reported identically (no existence oracle).
    return const Result.ok(null);
  }

  @override
  Future<Result<int>> unreadCount(UserId recipientId) async {
    final f = _takeFailure();
    if (f != null) return Result.err(f);
    final count = _rows
        .where((n) => n.recipientId.value == recipientId.value && !n.isRead)
        .length;
    return Result.ok(count);
  }
}

// ---------------------------------------------------------------------------
// Builders shared across the notification use-case tests.
// ---------------------------------------------------------------------------

/// Builds an authenticated principal at the given role.
AuthenticatedUser principalUser({
  required String userId,
  PlatformRole role = PlatformRole.user,
}) => AuthenticatedUser(userId: UserId(userId), role: role);

/// Builds a stored `roundScored` notification.
Notification storedRoundScored({
  required String id,
  required String recipientId,
  required String roundId,
  DateTime? createdAt,
  DateTime? readAt,
}) => Notification.fromStored(
  id: NotificationId(id),
  recipientId: UserId(recipientId),
  kind: NotificationKind.roundScored,
  subject: NotificationSubject.roundScored(roundId: RoundId(roundId)),
  createdAt: createdAt ?? DateTime.utc(2026, 7, 5, 12),
  readAt: readAt,
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

/// Canonical UUIDs handy for tests.
const uuidA = '11111111-1111-4111-8111-111111111111';
const uuidB = '22222222-2222-4222-8222-222222222222';
const uuidC = '33333333-3333-4333-8333-333333333333';
const uuidD = '44444444-4444-4444-8444-444444444444';
