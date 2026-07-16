import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:infrastructure/src/db/postgres_connection.dart';
import 'package:shared/shared.dart';

/// Postgres-backed [ActivityFeedReader] — a **pure read projection** over
/// existing ratified data (Social decision #2: the Activity Feed has NO table).
///
/// It assembles a group's feed by reading already-persisted truth and shaping it
/// into [ActivityEvent]s, newest-first, capped at the requested limit:
///
///   * **member_joined** — from `group.group_memberships.joined_at` for the
///     group (a member joining the circle is an activity event, decision #1).
///   * **round_scored** — from `competition.rounds` that reached `scored`
///     status in the seasons the group's members participate in. A round's
///     scored-transition instant is its `updated_at` (the round table's status
///     advances only `open → locked → scored`, so the last update on a
///     `scored` row is the scoring moment). The round is included only if at
///     least one of the group's members is a `participant` of its season — so
///     the feed shows rounds relevant to this circle (decision #1/#3), never an
///     arbitrary global round stream.
///
/// **rank_shift** is intentionally NOT produced by this reader. A rank delta is
/// the difference between two points in time; the platform stores no rank
/// history (the leaderboard is a live projection — Leaderboards §2), so a
/// single read cannot derive a *shift*. Emitting rank_shift correctly requires a
/// stored rank-snapshot history, which is a future additive change (a new
/// projection table) — deliberately deferred rather than faked here (no
/// placeholder). The `ActivityEventType.rankShift` shape exists in the contract
/// so that future work is purely additive.
///
/// The reader is *total* (Application ADR §2): it never throws. It speaks only
/// in the application read value [ActivityEvent] and typed ids; SQL and rows
/// never leak. A driver failure is surfaced as [ErrorKind.transient]; a
/// malformed row is mapped to a transient `social.row_corrupt`. All queries bind
/// values through `@named` parameters (Security ADR §2).
///
/// **Tier-3 degradation (decision #4):** a feed-assembly failure is a typed
/// `Result.err` confined to `GetGroupActivityFeed`; it never propagates into a
/// Tier-1 core operation.
final class PostgresActivityFeedReader implements ActivityFeedReader {
  /// Creates the reader over an open [PostgresConnection].
  const PostgresActivityFeedReader(this._connection);

  final PostgresConnection _connection;

  // A single UNION read produces both derivable event kinds already ordered
  // newest-first and capped, so the projection stays one round-trip and never
  // over-scans (a Tier-3 read must stay cheap — decision #4).
  //
  //   * member_joined: every membership row of the group, keyed by joined_at.
  //   * round_scored:  each scored round of a season in which at least one of
  //     the group's members is a participant, keyed by the round's updated_at
  //     (its scored-transition instant). DISTINCT because several of the group's
  //     members may participate in the same season/round.
  //
  // The `kind` discriminator column lets the mapper build the right event. The
  // unused id columns are NULL per branch (round_id null for member_joined,
  // user_id null for round_scored).
  static const String _feedSql = '''
SELECT * FROM (
  SELECT
    'member_joined'::text AS kind,
    NULL::uuid            AS round_id,
    m.user_id             AS user_id,
    m.joined_at           AS occurred_at
  FROM "group".group_memberships m
  WHERE m.group_id = @group_id

  UNION ALL

  SELECT DISTINCT
    'round_scored'::text  AS kind,
    r.id                  AS round_id,
    NULL::uuid            AS user_id,
    r.updated_at          AS occurred_at
  FROM competition.rounds r
  WHERE r.status = 'scored'
    AND EXISTS (
      SELECT 1
      FROM competition.participants p
      JOIN "group".group_memberships gm
        ON gm.user_id = p.user_id
      WHERE p.season_id = r.season_id
        AND gm.group_id = @group_id
    )
) AS feed
ORDER BY occurred_at DESC, round_id ASC NULLS LAST, user_id ASC NULLS LAST
LIMIT @limit
''';

  @override
  Future<Result<List<ActivityEvent>>> groupActivityFeed({
    required GroupId groupId,
    required int limit,
  }) async {
    final result = await _connection.query(
      _feedSql,
      parameters: {'group_id': groupId.value, 'limit': limit},
    );
    return switch (result) {
      Err<List<Map<String, dynamic>>>(:final error) => Result.err(error),
      Ok<List<Map<String, dynamic>>>(:final value) => _mapEvents(
        groupId,
        value,
      ),
    };
  }

  // --------------------------------------------------------------------------
  // Row mapping
  // --------------------------------------------------------------------------

  Result<List<ActivityEvent>> _mapEvents(
    GroupId groupId,
    List<Map<String, dynamic>> rows,
  ) {
    final events = <ActivityEvent>[];
    for (final row in rows) {
      final mapped = _mapEvent(groupId, row);
      if (mapped is Err<ActivityEvent>) {
        return Result.err(mapped.error);
      }
      events.add((mapped as Ok<ActivityEvent>).value);
    }
    return Result.ok(List<ActivityEvent>.unmodifiable(events));
  }

  Result<ActivityEvent> _mapEvent(GroupId groupId, Map<String, dynamic> row) {
    final kind = row['kind']?.toString();
    final occurredAt = _readUtcTimestamp(row['occurred_at']);
    if (occurredAt == null) {
      return Result.err(_corrupt('occurred_at', 'not a timestamp'));
    }

    switch (kind) {
      case 'member_joined':
        final userIdResult = UserId.tryParse(row['user_id']?.toString());
        if (userIdResult is Err<UserId>) {
          return Result.err(_corrupt('user_id', userIdResult.error.message));
        }
        return Result.ok(
          ActivityEvent.memberJoined(
            groupId: groupId,
            userId: (userIdResult as Ok<UserId>).value,
            occurredAt: occurredAt,
          ),
        );
      case 'round_scored':
        final roundIdResult = RoundId.tryParse(row['round_id']?.toString());
        if (roundIdResult is Err<RoundId>) {
          return Result.err(_corrupt('round_id', roundIdResult.error.message));
        }
        return Result.ok(
          ActivityEvent.roundScored(
            groupId: groupId,
            roundId: (roundIdResult as Ok<RoundId>).value,
            occurredAt: occurredAt,
          ),
        );
      default:
        return Result.err(_corrupt('kind', 'unknown event kind: $kind'));
    }
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
    'social.row_corrupt',
    'Assembled activity-feed row has invalid $field: $detail',
  );
}
