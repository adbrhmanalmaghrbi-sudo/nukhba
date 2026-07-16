/// Leaderboards (view) — a season's ranked standings
/// (`GET /seasons/{id}/leaderboard`).
///
/// Watches `seasonLeaderboardProvider(seasonId)` and renders its `entries` via
/// the shared [AsyncListView], so the four outcomes are handled consistently
/// with the Competition browse screens:
///   * **loading** — a spinner while the read is in flight;
///   * **success** — one row per participant showing their standard-competition
///     rank, participant id, and signed total points (the audit entry count is
///     shown as a subtitle). The order is the server-defined display order
///     (points desc, then joinedAt asc, then participant id asc) — the client
///     never re-sorts or recomputes anything (Axiom 5);
///   * **legitimate empty** — a season with no participants yields an empty
///     `entries` list, shown as an informational empty affordance, never an
///     error;
///   * **error** — a failure (including `401 leaderboard.not_a_participant` for
///     a non-member, a validation `400` for a malformed season id, or a
///     transient network failure) is rendered through `ErrorPresenter` via the
///     [AsyncListView]'s error view; the widget never branches on a raw code and
///     offers a retry affordance only when the failure is retryable.
///
/// This screen displays only what the server produced — it holds no ranking or
/// points logic and issues no write (a leaderboard is read-only, Axiom 2).
library;

import 'package:contracts/contracts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../competition/widgets/async_list_view.dart';
import 'leaderboards_providers.dart';

/// The ranked-standings screen for a single season.
class SeasonLeaderboardScreen extends ConsumerWidget {
  /// Creates the leaderboard screen for [seasonId].
  const SeasonLeaderboardScreen({
    required this.seasonId,
    required this.seasonLabel,
    super.key,
  });

  /// The owning season id whose standings are shown.
  final String seasonId;

  /// The season's display label (for the app bar; passed from the caller so no
  /// extra fetch is needed just to title this screen).
  final String seasonLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final standings = ref.watch(seasonLeaderboardProvider(seasonId));
    return Scaffold(
      appBar: AppBar(
        title: Text(
          '$seasonLabel — Leaderboard',
          key: const Key('leaderboard.title'),
        ),
      ),
      body: AsyncListView<LeaderboardEntryDto>(
        // The provider yields the whole DTO; the list view renders the
        // server-ordered entries (never re-sorted client-side).
        value: standings.whenData((board) => board.entries),
        emptyMessage: 'No one has joined this season yet.',
        onRetry: () => ref.invalidate(seasonLeaderboardProvider(seasonId)),
        itemBuilder: (context, entry) => _LeaderboardRow(entry: entry),
      ),
    );
  }
}

/// One participant's standings row: rank + participant id + signed points.
class _LeaderboardRow extends StatelessWidget {
  const _LeaderboardRow({required this.entry});

  final LeaderboardEntryDto entry;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      key: Key('leaderboard.item.${entry.participantId}'),
      leading: CircleAvatar(
        child: Text(
          '${entry.rank}',
          key: Key('leaderboard.rank.${entry.participantId}'),
        ),
      ),
      title: Text(
        entry.participantId,
        key: Key('leaderboard.participant.${entry.participantId}'),
      ),
      subtitle: Text(
        '${_pluralEntries(entry.entryCount)} counted',
        key: Key('leaderboard.entries.${entry.participantId}'),
      ),
      trailing: Text(
        '${entry.totalPoints} pts',
        key: Key('leaderboard.points.${entry.participantId}'),
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
    );
  }

  /// Humanises the audit [count] of ledger movements ("1 entry" / "N entries").
  static String _pluralEntries(int count) =>
      count == 1 ? '1 entry' : '$count entries';
}
