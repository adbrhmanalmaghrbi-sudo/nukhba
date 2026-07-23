import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:infrastructure/src/db/postgres_connection.dart';
// `postgres` exports its own `Result`; we only need its exception hierarchy
// here (to read the SQLSTATE `code`/`constraintName` off a `ServerException`),
// so hide `Result` to keep `Result<T>` unambiguously our `shared` union.
// `postgres` 3.x also exports a `Notification` type (LISTEN/NOTIFY channel
// payload) that collides with the domain `Notification` aggregate we speak in
// here; hide it too so `Notification` unambiguously means the domain type.
import 'package:postgres/postgres.dart' hide Result, Notification;
import 'package:shared/shared.dart';

/// Postgres-backed [NotificationRepository] over the `notification.notifications`
/// table (Database ADR; migration `0009_notification.sql`).
///
/// Notifications are the ONE new stored Tier-3 surface this phase introduces
/// (Notifications decision #3: genuinely stored, per-user, MUTABLE read-state).
/// A recipient has AT MOST ONE notification per distinct event — uniqueness
/// `(recipient_id, kind, subject_ref)` — so [createIfAbsent] is an idempotent
/// `INSERT … ON CONFLICT DO NOTHING`: a first create inserts (RETURNING id →
/// `Ok(true)`); a replayed trigger conflicts and inserts nothing
/// (`Ok(false)`) — never a second row, never an error. Reads and the mark are
/// recipient-scoped (decision #4) so a foreign id is invisible.
///
/// The adapter is *total* (Application ADR §2): it never throws. It speaks only
/// in the domain [Notification] aggregate and typed ids; SQL and rows never
/// leak. A driver failure is surfaced as [ErrorKind.transient]; a malformed row
/// is mapped to a transient `notification.row_corrupt`. All queries bind values
/// through `@named` parameters (Security ADR §2).
///
/// **Tier-3 degradation (decision #4; ADR 0007 §2.4):** a failure here is a
/// typed `Result.err` confined to the notification use-case that called it; it
/// never propagates into a Tier-1 core operation.
final class PostgresNotificationRepository implements NotificationRepository {
  /// Creates the repository over an open [PostgresConnection].
  const PostgresNotificationRepository(this._connection);

  final PostgresConnection _connection;

  // --------------------------------------------------------------------------
  // createIfAbsent — idempotent insert on the dedupe key
  // --------------------------------------------------------------------------

  // ON CONFLICT DO NOTHING on the dedupe key makes a replayed trigger a no-op:
  // an inserted row RETURNs its id (Ok(true)); a conflict returns no row
  // (Ok(false)). subject_ref is the deterministic NotificationSubject.dedupeRef,
  // so the same event dedupes and a distinct event does not. The nullable
  // subject columns (round/group/actor) are stored for the client to render +
  // deep-link; the dedupe is on subject_ref, not the individual columns.
  static const String _createSql = '''
INSERT INTO notification.notifications
  (id, recipient_id, kind, round_id, group_id, actor_user_id, subject_ref,
   read_at, created_at)
VALUES
  (@id, @recipient_id, @kind, @round_id, @group_id, @actor_user_id,
   @subject_ref, @read_at, @created_at)
ON CONFLICT ON CONSTRAINT notifications_dedupe_uniq DO NOTHING
RETURNING id
''';

  @override
  Future<Result<bool>> createIfAbsent(Notification notification) async {
    final subject = notification.subject;
    final result = await _connection.query(
      _createSql,
      parameters: {
        'id': notification.id.value,
        'recipient_id': notification.recipientId.value,
        'kind': notification.kind.wireValue,
        'round_id': subject.roundId?.value,
        'group_id': subject.groupId?.value,
        'actor_user_id': subject.actorUserId?.value,
        'subject_ref': subject.dedupeRef,
        'read_at': notification.readAt?.toUtc(),
        'created_at': notification.createdAt.toUtc(),
      },
    );
    return switch (result) {
      Err<List<Map<String, dynamic>>>(:final error) => _onCreateError(
        _reclassify(error),
      ),
      // A returned row means a genuine insert; an empty result means the
      // ON CONFLICT skip fired — an idempotent replay (never a second row).
      Ok<List<Map<String, dynamic>>>(:final value) => Result.ok(
        value.isNotEmpty,
      ),
    };
  }

  // A racing duplicate the DB rejects (`notification.duplicate`) is the SAME
  // outcome as the ON CONFLICT skip: nothing new was written. Converge it to
  // Ok(false) so a concurrent replay is still idempotent. Any other error
  // propagates unchanged.
  Result<bool> _onCreateError(AppError error) {
    if (error.code == 'notification.duplicate') {
      return const Result.ok(false);
    }
    return Result.err(error);
  }

  // --------------------------------------------------------------------------
  // listForRecipient — the recipient's own notifications, newest-first
  // --------------------------------------------------------------------------

  static const String _listSql = '''
SELECT id, recipient_id, kind::text, round_id, group_id, actor_user_id, read_at,
       created_at
FROM notification.notifications
WHERE recipient_id = @recipient_id
ORDER BY created_at DESC, id DESC
LIMIT @limit
''';

  @override
  Future<Result<List<Notification>>> listForRecipient(
    UserId recipientId, {
    required int limit,
  }) async {
    final result = await _connection.query(
      _listSql,
      parameters: {'recipient_id': recipientId.value, 'limit': limit},
    );
    return switch (result) {
      Err<List<Map<String, dynamic>>>(:final error) => Result.err(error),
      Ok<List<Map<String, dynamic>>>(:final value) => _mapMany(value),
    };
  }

  // --------------------------------------------------------------------------
  // findForRecipient — a recipient-owned notification, or null
  // --------------------------------------------------------------------------

  static const String _findSql = '''
SELECT id, recipient_id, kind::text, round_id, group_id, actor_user_id, read_at,
       created_at
FROM notification.notifications
WHERE id = @id AND recipient_id = @recipient_id
''';

  @override
  Future<Result<Notification?>> findForRecipient(
    NotificationId id,
    UserId recipientId,
  ) async {
    final result = await _connection.query(
      _findSql,
      parameters: {'id': id.value, 'recipient_id': recipientId.value},
    );
    return switch (result) {
      Err<List<Map<String, dynamic>>>(:final error) => Result.err(error),
      Ok<List<Map<String, dynamic>>>(:final value) =>
        value.isEmpty ? const Result.ok(null) : _mapOne(value.first),
    };
  }

  // --------------------------------------------------------------------------
  // markRead — recipient-scoped, idempotent unread→read transition
  // --------------------------------------------------------------------------

  // The WHERE clause is recipient-scoped so a foreign/absent id updates nothing
  // (RETURNING is empty → the read below reports Ok(null), which the use-case
  // refuses as `notification.not_found`, no existence oracle). Among the
  // recipient's own rows, the `read_at IS NULL` guard makes the mark idempotent:
  // an unread row transitions and RETURNs (Ok(true)); an already-read row
  // matches the recipient scope but not the guard, so we distinguish it from a
  // foreign id via a second recipient-scoped existence check.
  static const String _markSql = '''
UPDATE notification.notifications
SET read_at = @read_at
WHERE id = @id AND recipient_id = @recipient_id AND read_at IS NULL
RETURNING id
''';

  static const String _existsForRecipientSql = '''
SELECT 1
FROM notification.notifications
WHERE id = @id AND recipient_id = @recipient_id
''';

  @override
  Future<Result<bool?>> markRead(
    NotificationId id,
    UserId recipientId,
    DateTime readAt,
  ) async {
    final marked = await _connection.query(
      _markSql,
      parameters: {
        'id': id.value,
        'recipient_id': recipientId.value,
        'read_at': readAt.toUtc(),
      },
    );
    switch (marked) {
      case Err<List<Map<String, dynamic>>>(:final error):
        return Result.err(error);
      case Ok<List<Map<String, dynamic>>>(:final value):
        if (value.isNotEmpty) {
          // A row transitioned unread→read.
          return const Result.ok(true);
        }
    }

    // No row was updated: either the notification is already read (owned by the
    // recipient) or it is foreign/absent. Disambiguate with a recipient-scoped
    // existence check so an already-read notification is an idempotent
    // Ok(false) while a foreign/absent one is Ok(null) (→ not_found, no oracle).
    final exists = await _connection.query(
      _existsForRecipientSql,
      parameters: {'id': id.value, 'recipient_id': recipientId.value},
    );
    return switch (exists) {
      Err<List<Map<String, dynamic>>>(:final error) => Result.err(error),
      Ok<List<Map<String, dynamic>>>(:final value) =>
        value.isNotEmpty ? const Result.ok(false) : const Result.ok(null),
    };
  }

  // --------------------------------------------------------------------------
  // unreadCount — the recipient's unread total
  // --------------------------------------------------------------------------

  static const String _unreadCountSql = '''
SELECT count(*) AS unread
FROM notification.notifications
WHERE recipient_id = @recipient_id AND read_at IS NULL
''';

  @override
  Future<Result<int>> unreadCount(UserId recipientId) async {
    final result = await _connection.query(
      _unreadCountSql,
      parameters: {'recipient_id': recipientId.value},
    );
    return switch (result) {
      Err<List<Map<String, dynamic>>>(:final error) => Result.err(error),
      Ok<List<Map<String, dynamic>>>(:final value) => _mapCount(value),
    };
  }

  Result<int> _mapCount(List<Map<String, dynamic>> rows) {
    if (rows.isEmpty) {
      // count(*) always returns one row; an empty result is a corrupt read.
      return Result.err(_corrupt('unread', 'count query returned no row'));
    }
    final count = _readInt(rows.first['unread']);
    if (count == null) {
      return Result.err(_corrupt('unread', 'not an integer'));
    }
    return Result.ok(count);
  }

  // --------------------------------------------------------------------------
  // Row mapping
  // --------------------------------------------------------------------------

  Result<List<Notification>> _mapMany(List<Map<String, dynamic>> rows) {
    final notifications = <Notification>[];
    for (final row in rows) {
      final mapped = _mapOne(row);
      if (mapped is Err<Notification?>) {
        return Result.err(mapped.error);
      }
      final notification = (mapped as Ok<Notification?>).value;
      // _mapOne only returns Ok(null) on an absent row, which cannot happen
      // when mapping a present result row; guard defensively anyway.
      if (notification != null) {
        notifications.add(notification);
      }
    }
    return Result.ok(List<Notification>.unmodifiable(notifications));
  }

  Result<Notification?> _mapOne(Map<String, dynamic> row) {
    final idResult = NotificationId.tryParse(row['id']?.toString());
    if (idResult is Err<NotificationId>) {
      return Result.err(_corrupt('id', idResult.error.message));
    }
    final recipientResult = UserId.tryParse(row['recipient_id']?.toString());
    if (recipientResult is Err<UserId>) {
      return Result.err(
        _corrupt('recipient_id', recipientResult.error.message),
      );
    }
    final kindResult = NotificationKind.tryParse(row['kind']?.toString());
    if (kindResult is Err<NotificationKind>) {
      return Result.err(_corrupt('kind', kindResult.error.message));
    }
    final createdAt = _readUtcTimestamp(row['created_at']);
    if (createdAt == null) {
      return Result.err(_corrupt('created_at', 'not a timestamp'));
    }

    final kind = (kindResult as Ok<NotificationKind>).value;

    // read_at is nullable (unread when null); a present value must parse.
    DateTime? readAt;
    final rawReadAt = row['read_at'];
    if (rawReadAt != null) {
      readAt = _readUtcTimestamp(rawReadAt);
      if (readAt == null) {
        return Result.err(_corrupt('read_at', 'not a timestamp'));
      }
    }

    // Rebuild the kind-discriminated subject from the stored reference columns.
    final subjectResult = _mapSubject(kind, row);
    if (subjectResult is Err<NotificationSubject>) {
      return Result.err(subjectResult.error);
    }

    // fromStored performs only typing — the row is already trusted storage.
    return Result.ok(
      Notification.fromStored(
        id: (idResult as Ok<NotificationId>).value,
        recipientId: (recipientResult as Ok<UserId>).value,
        kind: kind,
        subject: (subjectResult as Ok<NotificationSubject>).value,
        createdAt: createdAt,
        readAt: readAt,
      ),
    );
  }

  // Rebuilds a NotificationSubject from the stored reference columns per the
  // kind's discriminant. A required reference that is absent or malformed is a
  // corrupt row (transient) — the row_corrupt guard mirrors the reaction
  // adapter's discipline.
  Result<NotificationSubject> _mapSubject(
    NotificationKind kind,
    Map<String, dynamic> row,
  ) {
    switch (kind) {
      case NotificationKind.roundScored:
        final roundResult = RoundId.tryParse(row['round_id']?.toString());
        if (roundResult is Err<RoundId>) {
          return Result.err(_corrupt('round_id', roundResult.error.message));
        }
        return Result.ok(
          NotificationSubject.roundScored(
            roundId: (roundResult as Ok<RoundId>).value,
          ),
        );
      case NotificationKind.groupMemberJoined:
        final groupResult = GroupId.tryParse(row['group_id']?.toString());
        if (groupResult is Err<GroupId>) {
          return Result.err(_corrupt('group_id', groupResult.error.message));
        }
        final actorResult = UserId.tryParse(row['actor_user_id']?.toString());
        if (actorResult is Err<UserId>) {
          return Result.err(
            _corrupt('actor_user_id', actorResult.error.message),
          );
        }
        return Result.ok(
          NotificationSubject.groupMemberJoined(
            groupId: (groupResult as Ok<GroupId>).value,
            actorUserId: (actorResult as Ok<UserId>).value,
          ),
        );
      case NotificationKind.reactionReceived:
        final groupResult = GroupId.tryParse(row['group_id']?.toString());
        if (groupResult is Err<GroupId>) {
          return Result.err(_corrupt('group_id', groupResult.error.message));
        }
        final roundResult = RoundId.tryParse(row['round_id']?.toString());
        if (roundResult is Err<RoundId>) {
          return Result.err(_corrupt('round_id', roundResult.error.message));
        }
        final actorResult = UserId.tryParse(row['actor_user_id']?.toString());
        if (actorResult is Err<UserId>) {
          return Result.err(
            _corrupt('actor_user_id', actorResult.error.message),
          );
        }
        return Result.ok(
          NotificationSubject.reactionReceived(
            groupId: (groupResult as Ok<GroupId>).value,
            roundId: (roundResult as Ok<RoundId>).value,
            actorUserId: (actorResult as Ok<UserId>).value,
          ),
        );
    }
  }

  // --------------------------------------------------------------------------
  // SQLSTATE reclassification (mirror the ledger/group/social adapters)
  // --------------------------------------------------------------------------

  AppError _reclassify(AppError error) {
    final cause = error.cause;
    if (cause is! ServerException) {
      return error;
    }
    final code = cause.code;
    // 23505 unique_violation (a concurrent duplicate that slipped past
    // ON CONFLICT — the create converges on it), 23503 foreign_key_violation
    // (the recipient, round, group, or actor vanished).
    const integrityCodes = {'23505', '23503'};
    if (code == null || !integrityCodes.contains(code)) {
      return error;
    }
    final constraint = cause.constraintName;
    if (constraint == 'notifications_dedupe_uniq') {
      // A concurrent trigger created the identical notification first; the
      // create use-case treats this as an idempotent skip.
      return const AppError.invariant(
        'notification.duplicate',
        'An identical notification already exists',
      );
    }
    if (constraint == 'notifications_recipient_id_fkey') {
      return const AppError.invariant(
        'notification.recipient_not_found',
        'Recipient not found',
      );
    }
    if (constraint == 'notifications_round_id_fkey') {
      return const AppError.invariant(
        'notification.round_not_found',
        'Round not found',
      );
    }
    if (constraint == 'notifications_group_id_fkey') {
      return const AppError.invariant(
        'notification.group_not_found',
        'Group not found',
      );
    }
    if (constraint == 'notifications_actor_user_id_fkey') {
      return const AppError.invariant(
        'notification.actor_not_found',
        'Actor user not found',
      );
    }
    return const AppError.invariant(
      'notification.integrity_violation',
      'The write violated a notification integrity rule',
    );
  }

  // count(*) / sums come back as int or BigInt depending on the driver path;
  // accept both plus a text fallback (mirror the leaderboard adapter's _readInt).
  static int? _readInt(Object? raw) {
    if (raw is int) return raw;
    if (raw is BigInt) return raw.toInt();
    if (raw is String) return int.tryParse(raw);
    return null;
  }

  static DateTime? _readUtcTimestamp(Object? raw) {
    if (raw is DateTime) {
      return raw.toUtc();
    }
    if (raw is String) {
      final parsed = DateTime.tryParse(raw);
      return parsed?.toUtc();
    }
    return null;
  }

  static AppError _corrupt(String field, String detail) => AppError.transient(
    'notification.row_corrupt',
    'Stored notifications row has invalid $field: $detail',
  );
}
