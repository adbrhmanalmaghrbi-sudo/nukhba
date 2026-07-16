import 'package:application/src/social/activity_event.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// Read-only port producing a group's activity feed — a **pure projection**
/// over existing ratified data (Social decision #2: the feed has NO table; it is
/// assembled by reading `group.group_memberships`, scored `competition.rounds` +
/// `ledger` postings, and `leaderboard.season_standings` rank deltas). No writes
/// happen through this port; it is a read of already-persisted truth.
///
/// Backed by `PostgresActivityFeedReader`. Speaks in the application read value
/// [ActivityEvent] and typed ids, never rows or SQL.
///
/// Contract (Application ADR §2):
/// * MUST NOT throw — every outcome is a typed [Result].
/// * MUST map infrastructure failures to [ErrorKind.transient].
///
/// **Tier-3 degradation (decision #4):** a failure here is confined to the
/// `GetGroupActivityFeed` use-case; a feed-assembly error MUST NOT block or fail
/// any Tier-1 core operation.
abstract interface class ActivityFeedReader {
  /// Assembles the most recent activity for [groupId], newest first
  /// (occurredAt descending), capped at [limit] events. The events are
  /// group-scoped by construction — an event is included only if it belongs to
  /// this group's membership/rounds. An empty list is legitimate (a fresh
  /// group).
  Future<Result<List<ActivityEvent>>> groupActivityFeed({
    required GroupId groupId,
    required int limit,
  });
}
