import 'package:domain/domain.dart';
import 'package:infrastructure/src/db/postgres_connection.dart';
import 'package:infrastructure/src/notification/postgres_notification_repository.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

/// Hermetic unit tests for [PostgresNotificationRepository].
///
/// These do NOT require a live database. They substitute a fake
/// [PostgresConnection] that records the SQL + parameters of each call and
/// replies with a scripted [Result] per call (mirroring `test/social`,
/// `test/group`, etc.), so we drive every *pure* branch the adapter owns:
///   * `createIfAbsent` — the idempotent `INSERT … ON CONFLICT ON CONSTRAINT
///     notifications_dedupe_uniq DO NOTHING RETURNING id`: `@named`-bound
///     (kind as its wire token, subject_ref = the deterministic dedupeRef, the
///     nullable subject columns per kind, timestamps coerced to UTC), Ok(true)
///     when a row RETURNed (a genuine insert), Ok(false) when the conflict skip
///     fired (empty result — a replayed trigger), and verbatim pass-through of a
///     transient failure;
///   * `listForRecipient` — the recipient-scoped `ORDER BY created_at DESC,
///     id DESC LIMIT @limit` shape + binding, newest-first row → [Notification]
///     mapping across all three kinds, empty on absence;
///   * `findForRecipient` — recipient-scoped `WHERE id AND recipient_id` shape +
///     binding, row → [Notification] mapping, and `Ok(null)` on an empty result
///     (foreign/absent id — no existence oracle);
///   * `markRead` — the recipient-scoped, `read_at IS NULL`-guarded
///     `UPDATE … RETURNING id` transitioning unread→read (`Ok(true)`), and the
///     second recipient-scoped existence probe that disambiguates an already-read
///     owned row (`Ok(false)`) from a foreign/absent id (`Ok(null)`);
///   * `unreadCount` — the recipient-scoped `count(*) WHERE read_at IS NULL`
///     shape + binding and int/BigInt/text coercion;
///   * verbatim pass-through of a transient query failure on every method;
///   * corrupt-row mapping (`notification.row_corrupt`) for a bad id /
///     recipient_id / kind / created_at / read_at, and for a missing/malformed
///     required subject reference on each kind.
///
/// The one branch that genuinely needs the driver — reclassifying a `postgres`
/// [ServerException] into a domain `invariant` via the violated constraint name
/// (`notifications_dedupe_uniq` → `notification.duplicate`, the four FK names →
/// `notification.recipient_not_found` / `round_not_found` / `group_not_found` /
/// `actor_not_found`) — is deliberately NOT exercised here: the driver's
/// `ServerException` has no public constructor, so that path can only be
/// verified honestly against real Postgres (a DB-gated integration test, as the
/// social/ledger adapters do). The `_onCreateError` convergence of an ALREADY
/// domain-classified `notification.duplicate` to `Ok(false)` IS exercised below,
/// since that takes a plain [AppError] we can construct.

const _notificationId = '11111111-1111-1111-1111-111111111111';
const _recipientId = '22222222-2222-2222-2222-222222222222';
const _roundId = '33333333-3333-3333-3333-333333333333';
const _groupId = '44444444-4444-4444-4444-444444444444';
const _actorId = '55555555-5555-5555-5555-555555555555';

/// A [PostgresConnection] test double that records the SQL + parameters of each
/// call and replies with a scripted [Result] per call (falling back to the last
/// scripted response once exhausted). It never touches a real pool, so the whole
/// test is hermetic.
final class _FakeConnection implements PostgresConnection {
  _FakeConnection(this._responses);

  final List<Result<List<Map<String, dynamic>>>> _responses;
  int _index = 0;

  final List<String> sqls = [];
  final List<Map<String, Object?>> parameters = [];

  @override
  Future<Result<List<Map<String, dynamic>>>> query(
    String sql, {
    Map<String, Object?> parameters = const {},
  }) async {
    sqls.add(sql);
    this.parameters.add(parameters);
    final response =
        _responses[_index < _responses.length ? _index : _responses.length - 1];
    _index++;
    return response;
  }

  @override
  Future<Result<bool>> ping() async => const Result.ok(true);

  @override
  Future<Result<T>> runInTransaction<T>(
    Future<Result<T>> Function(DbExecutor tx) action,
  ) => action(this);

  @override
  Future<void> close() async {}
}

_FakeConnection _rows(List<Map<String, dynamic>> rows) =>
    _FakeConnection([Result.ok(rows)]);

/// A fake scripting a sequence of responses (for the two-query `markRead`).
_FakeConnection _sequence(List<Result<List<Map<String, dynamic>>>> responses) =>
    _FakeConnection(responses);

_FakeConnection _fails() => _FakeConnection([
  const Result.err(
    AppError.transient('db.query_failed', 'Database query failed'),
  ),
]);

Result<List<Map<String, dynamic>>> _ok(List<Map<String, dynamic>> rows) =>
    Result.ok(rows);
Result<List<Map<String, dynamic>>> get _err => const Result.err(
  AppError.transient('db.query_failed', 'Database query failed'),
);

NotificationId get _nId =>
    (NotificationId.tryParse(_notificationId) as Ok<NotificationId>).value;
UserId get _recipient => (UserId.tryParse(_recipientId) as Ok<UserId>).value;
RoundId get _rId => (RoundId.tryParse(_roundId) as Ok<RoundId>).value;
GroupId get _gId => (GroupId.tryParse(_groupId) as Ok<GroupId>).value;
UserId get _actor => (UserId.tryParse(_actorId) as Ok<UserId>).value;

Notification _roundScored({DateTime? readAt}) => Notification.fromStored(
  id: _nId,
  recipientId: _recipient,
  kind: NotificationKind.roundScored,
  subject: NotificationSubject.roundScored(roundId: _rId),
  createdAt: DateTime.utc(2026, 7, 13, 9, 30),
  readAt: readAt,
);

Notification _groupMemberJoined() => Notification.fromStored(
  id: _nId,
  recipientId: _recipient,
  kind: NotificationKind.groupMemberJoined,
  subject: NotificationSubject.groupMemberJoined(
    groupId: _gId,
    actorUserId: _actor,
  ),
  createdAt: DateTime.utc(2026, 7, 13, 9, 30),
  readAt: null,
);

Notification _reactionReceived() => Notification.fromStored(
  id: _nId,
  recipientId: _recipient,
  kind: NotificationKind.reactionReceived,
  subject: NotificationSubject.reactionReceived(
    groupId: _gId,
    roundId: _rId,
    actorUserId: _actor,
  ),
  createdAt: DateTime.utc(2026, 7, 13, 9, 30),
  readAt: null,
);

/// A stored row for a `round_scored` notification (group/actor columns null).
Map<String, dynamic> _roundScoredRow({
  String id = _notificationId,
  String recipientId = _recipientId,
  Object kind = 'round_scored',
  Object? roundId = _roundId,
  Object createdAt = '2026-07-13T09:30:00.000Z',
  Object? readAt,
}) => {
  'id': id,
  'recipient_id': recipientId,
  'kind': kind,
  'round_id': roundId,
  'group_id': null,
  'actor_user_id': null,
  'read_at': readAt,
  'created_at': createdAt,
};

Map<String, dynamic> _groupJoinRow({
  Object? groupId = _groupId,
  Object? actorUserId = _actorId,
}) => {
  'id': _notificationId,
  'recipient_id': _recipientId,
  'kind': 'group_member_joined',
  'round_id': null,
  'group_id': groupId,
  'actor_user_id': actorUserId,
  'read_at': null,
  'created_at': '2026-07-13T09:30:00.000Z',
};

Map<String, dynamic> _reactionRow({
  Object? groupId = _groupId,
  Object? roundId = _roundId,
  Object? actorUserId = _actorId,
}) => {
  'id': _notificationId,
  'recipient_id': _recipientId,
  'kind': 'reaction_received',
  'round_id': roundId,
  'group_id': groupId,
  'actor_user_id': actorUserId,
  'read_at': null,
  'created_at': '2026-07-13T09:30:00.000Z',
};

void main() {
  group('PostgresNotificationRepository.createIfAbsent', () {
    test('runs the idempotent ON CONFLICT DO NOTHING insert, @named-bound with '
        'the wire token, dedupeRef, and UTC timestamps', () async {
      // A returned row => a genuine insert => Ok(true).
      final conn = _rows([
        {'id': _notificationId},
      ]);
      final repo = PostgresNotificationRepository(conn);

      final result = await repo.createIfAbsent(_roundScored());

      expect((result as Ok<bool>).value, isTrue);
      expect(
        conn.sqls.single,
        contains('INSERT INTO notification.notifications'),
      );
      expect(
        conn.sqls.single,
        contains(
          'ON CONFLICT ON CONSTRAINT notifications_dedupe_uniq '
          'DO NOTHING',
        ),
      );
      expect(conn.sqls.single, contains('RETURNING id'));
      final params = conn.parameters.single;
      expect(params['id'], _notificationId);
      expect(params['recipient_id'], _recipientId);
      // Kind is bound as its stable wire token, never the enum name.
      expect(params['kind'], 'round_scored');
      expect(params['round_id'], _roundId);
      // round_scored carries no group/actor references.
      expect(params['group_id'], isNull);
      expect(params['actor_user_id'], isNull);
      // subject_ref is the deterministic dedupeRef keying the idempotency uniq.
      expect(params['subject_ref'], 'round:$_roundId');
      // A brand-new notification is unread.
      expect(params['read_at'], isNull);
      expect(params['created_at'], isA<DateTime>());
      expect((params['created_at']! as DateTime).isUtc, isTrue);
    });

    test(
      'an empty RETURNING result is an idempotent conflict-skip => Ok(false)',
      () async {
        // ON CONFLICT DO NOTHING fired: no row returned => a replayed trigger.
        final repo = PostgresNotificationRepository(_rows(const []));

        final result = await repo.createIfAbsent(_roundScored());

        expect((result as Ok<bool>).value, isFalse);
      },
    );

    test('binds the group_member_joined subject columns + dedupeRef', () async {
      final conn = _rows([
        {'id': _notificationId},
      ]);
      final repo = PostgresNotificationRepository(conn);

      await repo.createIfAbsent(_groupMemberJoined());

      final params = conn.parameters.single;
      expect(params['kind'], 'group_member_joined');
      expect(params['group_id'], _groupId);
      expect(params['actor_user_id'], _actorId);
      expect(params['round_id'], isNull);
      expect(params['subject_ref'], 'group_join:$_groupId:$_actorId');
    });

    test('binds the reaction_received subject columns + dedupeRef', () async {
      final conn = _rows([
        {'id': _notificationId},
      ]);
      final repo = PostgresNotificationRepository(conn);

      await repo.createIfAbsent(_reactionReceived());

      final params = conn.parameters.single;
      expect(params['kind'], 'reaction_received');
      expect(params['group_id'], _groupId);
      expect(params['round_id'], _roundId);
      expect(params['actor_user_id'], _actorId);
      expect(params['subject_ref'], 'reaction:$_groupId:$_roundId:$_actorId');
    });

    test('binds a set read_at as a UTC DateTime', () async {
      final conn = _rows([
        {'id': _notificationId},
      ]);
      final repo = PostgresNotificationRepository(conn);

      await repo.createIfAbsent(
        _roundScored(readAt: DateTime.utc(2026, 7, 13, 10)),
      );

      final readAt = conn.parameters.single['read_at'];
      expect(readAt, isA<DateTime>());
      expect((readAt! as DateTime).isUtc, isTrue);
    });

    test('passes a transient failure through verbatim', () async {
      final repo = PostgresNotificationRepository(_fails());

      final result = await repo.createIfAbsent(_roundScored());

      expect((result as Err<bool>).error.kind, ErrorKind.transient);
    });
  });

  group('PostgresNotificationRepository.listForRecipient', () {
    test('maps rows newest-first, binds recipient + limit, across all three '
        'kinds', () async {
      final conn = _rows([_roundScoredRow(), _groupJoinRow(), _reactionRow()]);
      final repo = PostgresNotificationRepository(conn);

      final result = await repo.listForRecipient(_recipient, limit: 20);

      final notifications = (result as Ok<List<Notification>>).value;
      expect(notifications.length, 3);
      expect(notifications[0].kind, NotificationKind.roundScored);
      expect(notifications[0].subject.roundId, _rId);
      expect(notifications[1].kind, NotificationKind.groupMemberJoined);
      expect(notifications[1].subject.groupId, _gId);
      expect(notifications[1].subject.actorUserId, _actor);
      expect(notifications[2].kind, NotificationKind.reactionReceived);
      expect(notifications[2].subject.roundId, _rId);
      expect(notifications[2].subject.groupId, _gId);
      expect(notifications[2].subject.actorUserId, _actor);
      expect(conn.sqls.single, contains('FROM notification.notifications'));
      expect(conn.sqls.single, contains('WHERE recipient_id = @recipient_id'));
      expect(conn.sqls.single, contains('ORDER BY created_at DESC, id DESC'));
      expect(conn.sqls.single, contains('LIMIT @limit'));
      expect(conn.parameters.single, {
        'recipient_id': _recipientId,
        'limit': 20,
      });
    });

    test('a recipient with no notifications yields Ok(empty)', () async {
      final repo = PostgresNotificationRepository(_rows(const []));

      final result = await repo.listForRecipient(_recipient, limit: 20);

      expect((result as Ok<List<Notification>>).value, isEmpty);
    });

    test('a read row maps readAt to a UTC instant (isRead)', () async {
      final repo = PostgresNotificationRepository(
        _rows([_roundScoredRow(readAt: '2026-07-13T10:00:00.000Z')]),
      );

      final result = await repo.listForRecipient(_recipient, limit: 20);

      final notification = (result as Ok<List<Notification>>).value.single;
      expect(notification.isRead, isTrue);
      expect(notification.readAt!.isUtc, isTrue);
    });

    test('a corrupt row fails the whole list with row_corrupt', () async {
      final repo = PostgresNotificationRepository(
        _rows([_roundScoredRow(kind: 'not-a-kind')]),
      );

      final result = await repo.listForRecipient(_recipient, limit: 20);

      expect(
        (result as Err<List<Notification>>).error.code,
        'notification.row_corrupt',
      );
    });

    test('passes a transient failure through verbatim', () async {
      final repo = PostgresNotificationRepository(_fails());

      final result = await repo.listForRecipient(_recipient, limit: 20);

      expect(
        (result as Err<List<Notification>>).error.kind,
        ErrorKind.transient,
      );
    });
  });

  group('PostgresNotificationRepository.findForRecipient', () {
    test(
      'maps a row to a Notification and binds the (id, recipient) key',
      () async {
        final conn = _rows([_roundScoredRow()]);
        final repo = PostgresNotificationRepository(conn);

        final result = await repo.findForRecipient(_nId, _recipient);

        final notification = (result as Ok<Notification?>).value!;
        expect(notification.id.value, _notificationId);
        expect(notification.recipientId, _recipient);
        expect(notification.kind, NotificationKind.roundScored);
        expect(notification.isRead, isFalse);
        expect(conn.sqls.single, contains('FROM notification.notifications'));
        expect(
          conn.sqls.single,
          contains('WHERE id = @id AND recipient_id = @recipient_id'),
        );
        expect(conn.parameters.single, {
          'id': _notificationId,
          'recipient_id': _recipientId,
        });
      },
    );

    test(
      'returns Ok(null) for a foreign/absent id (no existence oracle)',
      () async {
        final repo = PostgresNotificationRepository(_rows(const []));

        final result = await repo.findForRecipient(_nId, _recipient);

        expect((result as Ok<Notification?>).value, isNull);
      },
    );

    test('passes a transient failure through verbatim', () async {
      final repo = PostgresNotificationRepository(_fails());

      final result = await repo.findForRecipient(_nId, _recipient);

      expect((result as Err<Notification?>).error.kind, ErrorKind.transient);
    });

    test('maps a corrupt id to a transient row_corrupt', () async {
      final repo = PostgresNotificationRepository(
        _rows([_roundScoredRow(id: 'not-a-uuid')]),
      );

      final result = await repo.findForRecipient(_nId, _recipient);

      final error = (result as Err<Notification?>).error;
      expect(error.kind, ErrorKind.transient);
      expect(error.code, 'notification.row_corrupt');
    });

    test('maps a corrupt recipient id to a transient row_corrupt', () async {
      final repo = PostgresNotificationRepository(
        _rows([_roundScoredRow(recipientId: 'not-a-uuid')]),
      );

      final result = await repo.findForRecipient(_nId, _recipient);

      expect(
        (result as Err<Notification?>).error.code,
        'notification.row_corrupt',
      );
    });

    test('maps an unknown kind token to a transient row_corrupt', () async {
      final repo = PostgresNotificationRepository(
        _rows([_roundScoredRow(kind: 'not-a-kind')]),
      );

      final result = await repo.findForRecipient(_nId, _recipient);

      expect(
        (result as Err<Notification?>).error.code,
        'notification.row_corrupt',
      );
    });

    test('maps an absent created_at to a transient row_corrupt', () async {
      final repo = PostgresNotificationRepository(
        _rows([_roundScoredRow(createdAt: 42)]),
      );

      final result = await repo.findForRecipient(_nId, _recipient);

      expect(
        (result as Err<Notification?>).error.code,
        'notification.row_corrupt',
      );
    });

    test('maps a malformed read_at to a transient row_corrupt', () async {
      final repo = PostgresNotificationRepository(
        _rows([_roundScoredRow(readAt: 42)]),
      );

      final result = await repo.findForRecipient(_nId, _recipient);

      expect(
        (result as Err<Notification?>).error.code,
        'notification.row_corrupt',
      );
    });

    test('maps a round_scored row with a missing round_id to a row_corrupt '
        '(required subject reference)', () async {
      final repo = PostgresNotificationRepository(
        _rows([_roundScoredRow(roundId: null)]),
      );

      final result = await repo.findForRecipient(_nId, _recipient);

      expect(
        (result as Err<Notification?>).error.code,
        'notification.row_corrupt',
      );
    });

    test(
      'maps a group_member_joined row with a missing actor to a row_corrupt',
      () async {
        final repo = PostgresNotificationRepository(
          _rows([_groupJoinRow(actorUserId: null)]),
        );

        final result = await repo.findForRecipient(_nId, _recipient);

        expect(
          (result as Err<Notification?>).error.code,
          'notification.row_corrupt',
        );
      },
    );

    test(
      'maps a reaction_received row with a missing group to a row_corrupt',
      () async {
        final repo = PostgresNotificationRepository(
          _rows([_reactionRow(groupId: null)]),
        );

        final result = await repo.findForRecipient(_nId, _recipient);

        expect(
          (result as Err<Notification?>).error.code,
          'notification.row_corrupt',
        );
      },
    );
  });

  group('PostgresNotificationRepository.markRead', () {
    test(
      'an unread owned row transitions unread→read => Ok(true), bound',
      () async {
        // First query (the guarded UPDATE) RETURNs the id → a transition.
        final conn = _rows([
          {'id': _notificationId},
        ]);
        final repo = PostgresNotificationRepository(conn);
        final readAt = DateTime.utc(2026, 7, 13, 11);

        final result = await repo.markRead(_nId, _recipient, readAt);

        expect((result as Ok<bool?>).value, isTrue);
        // Only the UPDATE ran — no disambiguation probe needed on a transition.
        expect(conn.sqls.length, 1);
        expect(conn.sqls.single, contains('UPDATE notification.notifications'));
        expect(conn.sqls.single, contains('SET read_at = @read_at'));
        expect(
          conn.sqls.single,
          contains(
            'WHERE id = @id AND recipient_id = @recipient_id '
            'AND read_at IS NULL',
          ),
        );
        expect(conn.sqls.single, contains('RETURNING id'));
        final params = conn.parameters.single;
        expect(params['id'], _notificationId);
        expect(params['recipient_id'], _recipientId);
        expect(params['read_at'], isA<DateTime>());
        expect((params['read_at']! as DateTime).isUtc, isTrue);
      },
    );

    test('an already-read OWNED row (UPDATE empty, existence probe hits) => '
        'Ok(false), idempotent', () async {
      // UPDATE matched nothing (already read) → existence probe finds the row.
      final conn = _sequence([
        _ok(const []), // guarded UPDATE: no unread row to transition
        _ok([
          {'exists': 1},
        ]), // recipient-scoped existence probe: the row IS the recipient's
      ]);
      final repo = PostgresNotificationRepository(conn);

      final result = await repo.markRead(
        _nId,
        _recipient,
        DateTime.utc(2026, 7, 13, 11),
      );

      expect((result as Ok<bool?>).value, isFalse);
      expect(conn.sqls.length, 2);
      // The second query is the recipient-scoped existence check.
      expect(conn.sqls[1], contains('FROM notification.notifications'));
      expect(
        conn.sqls[1],
        contains('WHERE id = @id AND recipient_id = @recipient_id'),
      );
      expect(conn.parameters[1], {
        'id': _notificationId,
        'recipient_id': _recipientId,
      });
    });

    test(
      'a foreign/absent id (UPDATE empty, existence probe empty) => Ok(null), '
      'no existence oracle',
      () async {
        final conn = _sequence([
          _ok(const []), // guarded UPDATE: nothing matched
          _ok(const []), // existence probe: not the recipient's row (or absent)
        ]);
        final repo = PostgresNotificationRepository(conn);

        final result = await repo.markRead(
          _nId,
          _recipient,
          DateTime.utc(2026, 7, 13, 11),
        );

        expect((result as Ok<bool?>).value, isNull);
        expect(conn.sqls.length, 2);
      },
    );

    test('passes a transient failure on the UPDATE through verbatim', () async {
      final repo = PostgresNotificationRepository(_fails());

      final result = await repo.markRead(
        _nId,
        _recipient,
        DateTime.utc(2026, 7, 13, 11),
      );

      expect((result as Err<bool?>).error.kind, ErrorKind.transient);
    });

    test(
      'passes a transient failure on the existence probe through verbatim',
      () async {
        final conn = _sequence([
          _ok(const []), // UPDATE matched nothing
          _err, // the disambiguation probe fails transiently
        ]);
        final repo = PostgresNotificationRepository(conn);

        final result = await repo.markRead(
          _nId,
          _recipient,
          DateTime.utc(2026, 7, 13, 11),
        );

        expect((result as Err<bool?>).error.kind, ErrorKind.transient);
      },
    );
  });

  group('PostgresNotificationRepository.unreadCount', () {
    test('runs the recipient-scoped unread count, bound', () async {
      final conn = _rows([
        {'unread': 7},
      ]);
      final repo = PostgresNotificationRepository(conn);

      final result = await repo.unreadCount(_recipient);

      expect((result as Ok<int>).value, 7);
      expect(conn.sqls.single, contains('count(*)'));
      expect(conn.sqls.single, contains('FROM notification.notifications'));
      expect(
        conn.sqls.single,
        contains('WHERE recipient_id = @recipient_id AND read_at IS NULL'),
      );
      expect(conn.parameters.single, {'recipient_id': _recipientId});
    });

    test('coerces a BigInt count (driver path) to an int', () async {
      final repo = PostgresNotificationRepository(
        _rows([
          {'unread': BigInt.from(3)},
        ]),
      );

      final result = await repo.unreadCount(_recipient);

      expect((result as Ok<int>).value, 3);
    });

    test('coerces a text count to an int', () async {
      final repo = PostgresNotificationRepository(
        _rows([
          {'unread': '5'},
        ]),
      );

      final result = await repo.unreadCount(_recipient);

      expect((result as Ok<int>).value, 5);
    });

    test('zero unread is a legitimate Ok(0)', () async {
      final repo = PostgresNotificationRepository(
        _rows([
          {'unread': 0},
        ]),
      );

      final result = await repo.unreadCount(_recipient);

      expect((result as Ok<int>).value, 0);
    });

    test(
      'an empty count result is a corrupt read (count always returns a row)',
      () async {
        final repo = PostgresNotificationRepository(_rows(const []));

        final result = await repo.unreadCount(_recipient);

        expect((result as Err<int>).error.code, 'notification.row_corrupt');
      },
    );

    test('a non-numeric count is a corrupt read', () async {
      final repo = PostgresNotificationRepository(
        _rows([
          {'unread': 'not-a-number'},
        ]),
      );

      final result = await repo.unreadCount(_recipient);

      expect((result as Err<int>).error.code, 'notification.row_corrupt');
    });

    test('passes a transient failure through verbatim', () async {
      final repo = PostgresNotificationRepository(_fails());

      final result = await repo.unreadCount(_recipient);

      expect((result as Err<int>).error.kind, ErrorKind.transient);
    });
  });
}
