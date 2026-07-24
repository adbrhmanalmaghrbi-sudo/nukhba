/// Leaderboards (view) — a season's ranked standings
/// (GET /seasons/{id}/leaderboard).
///
/// Watches seasonLeaderboardProvider(seasonId) and renders its entries via
/// the shared [AsyncListView], so the four outcomes are handled consistently
/// with the Competition browse screens:
///   * loading — a spinner while the read is in flight;
///   * success — one row per participant showing their standard-competition
///     rank, participant id, and signed total points (the audit entry count is
///     shown as a subtitle). The order is the server-defined display order
///     (points desc, then joinedAt asc, then participant id asc) — the client
///     never re-sorts or recomputes anything (Axiom 5);
///   * legitimate empty — a season with no participants yields an empty
///     entries list, shown as an informational empty affordance, never an
///     error;
///   * error — a failure (including 401 leaderboard.not_a_participant for
///     a non-member, a validation 400, or a transient network failure) is
///     rendered through ErrorPresenter via the [AsyncListView]'s error view;
///     the widget never branches on a raw code and offers a retry affordance
///     only when the failure is retryable.
///
/// This screen displays only what the server produced — it holds no ranking or
/// points logic and issues no write (a leaderboard is read-only, Axiom 2).
///
/// Presentation note: the row paints with [AppColors] directly (not
/// Theme.of(context).colorScheme). The leaderboard widget tests mount this
/// screen under a bare MaterialApp with no AppTheme in scope, so relying on
/// the color scheme would yield undefined colors under test; painting from the
/// design-system constants keeps the visuals identical in app and test. The top
/// three ranks receive a gold / silver / bronze podium accent.
library;

import 'package:contracts/contracts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../competition/widgets/async_list_view.dart';
import 'leaderboards_providers.dart';

class SeasonLeaderboardScreen extends ConsumerWidget {
  const SeasonLeaderboardScreen({
    required this.seasonId,
    required this.seasonLabel,
    super.key,
  });

  final String seasonId;
  final String seasonLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue standings = ref.watch(
      seasonLeaderboardProvider(seasonId),
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(
          '$seasonLabel — Leaderboard',
          key: const Key('leaderboard.title'),
        ),
      ),
      body: AsyncListView(
        value: standings.whenData((board) => board.entries),
        emptyMessage: 'No one has joined this season yet.',
        onRetry: () => ref.invalidate(seasonLeaderboardProvider(seasonId)),
        itemBuilder: (context, entry) => _LeaderboardRow(entry: entry),
      ),
    );
  }
}

class _LeaderboardRow extends StatelessWidget {
  const _LeaderboardRow({required this.entry});

  final LeaderboardEntryDto entry;

  @override
  Widget build(BuildContext context) {
    final _Podium podium = _Podium.forRank(entry.rank);

    return Container(
      key: Key('leaderboard.item.${entry.participantId}'),
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: podium.isPodium
              ? podium.accent.withValues(alpha: 0.55)
              : AppColors.border,
        ),
      ),
      child: Row(
        children: [
          _RankBadge(
            rank: entry.rank,
            podium: podium,
            rankKey: Key('leaderboard.rank.${entry.participantId}'),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.participantId,
                  key: Key('leaderboard.participant.${entry.participantId}'),
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${_pluralEntries(entry.entryCount)} counted',
                  key: Key('leaderboard.entries.${entry.participantId}'),
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Text(
            '${entry.totalPoints} pts',
            key: Key('leaderboard.points.${entry.participantId}'),
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 16,
              color: podium.isPodium ? podium.accent : AppColors.primary,
            ),
          ),
        ],
      ),
    );
  }

  static String _pluralEntries(int count) =>
      count == 1 ? '1 entry' : '$count entries';
}

class _RankBadge extends StatelessWidget {
  const _RankBadge({
    required this.rank,
    required this.podium,
    required this.rankKey,
  });

  final int rank;
  final _Podium podium;
  final Key rankKey;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: podium.isPodium
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  podium.accent,
                  podium.accent.withValues(alpha: 0.7),
                ],
              )
            : null,
        color: podium.isPodium ? null : AppColors.surfaceHigh,
      ),
      child: Text(
        '$rank',
        key: rankKey,
        style: TextStyle(
          fontWeight: FontWeight.bold,
          fontSize: 15,
          color: podium.isPodium ? podium.onAccent : AppColors.textSecondary,
        ),
      ),
    );
  }
}

class _Podium {
  const _Podium({
    required this.isPodium,
    required this.accent,
    required this.onAccent,
  });

  final bool isPodium;
  final Color accent;
  final Color onAccent;

  static _Podium forRank(int rank) => switch (rank) {
    1 => const _Podium(
      isPodium: true,
      accent: AppColors.gold,
      onAccent: AppColors.onGold,
    ),
    2 => const _Podium(
      isPodium: true,
      accent: AppColors.silver,
      onAccent: AppColors.onSilver,
    ),
    3 => const _Podium(
      isPodium: true,
      accent: AppColors.bronze,
      onAccent: AppColors.onBronze,
    ),
    _ => const _Podium(
      isPodium: false,
      accent: AppColors.primary,
      onAccent: AppColors.onPrimary,
    ),
  };
}
