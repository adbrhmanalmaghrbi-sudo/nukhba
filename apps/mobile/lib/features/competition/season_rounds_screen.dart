/// Browse level 3 — a season's rounds (`GET /seasons/{id}/rounds`).
///
/// Watches `seasonRoundsProvider(seasonId)` and renders it via [AsyncListView].
/// A season with no rounds (or one that does not exist) is a *legitimate* empty
/// list. Each round shows its 1-based sequence, lifecycle status, and prediction
/// deadline; only the ruleset *version* is available on the DTO (never the
/// opaque frozen snapshot). Selecting a round pushes its fixtures
/// ([RoundFixturesScreen]).
///
/// This screen also carries the single, additive entry point into the
/// Leaderboards (view) slice: an app-bar action that pushes the season's ranked
/// standings ([SeasonLeaderboardScreen]). The button is a pure navigation
/// addition — the browse read logic above is untouched.
library;

import 'package:contracts/contracts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../leaderboards/season_leaderboard_screen.dart';
import 'competition_providers.dart';
import 'round_fixtures_screen.dart';
import 'widgets/async_list_view.dart';

/// The round-list screen for a single season.
class SeasonRoundsScreen extends ConsumerWidget {
  /// Creates the rounds screen for [seasonId].
  const SeasonRoundsScreen({
    required this.seasonId,
    required this.seasonLabel,
    super.key,
  });

  /// The owning season id whose rounds are listed.
  final String seasonId;

  /// The season's display label (for the app bar; passed from level 2).
  final String seasonLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rounds = ref.watch(seasonRoundsProvider(seasonId));
    return Scaffold(
      appBar: AppBar(
        title: Text('$seasonLabel — Rounds', key: const Key('rounds.title')),
        actions: <Widget>[
          IconButton(
            key: const Key('rounds.viewLeaderboard'),
            tooltip: 'View leaderboard',
            icon: const Icon(Icons.leaderboard_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SeasonLeaderboardScreen(
                  seasonId: seasonId,
                  seasonLabel: seasonLabel,
                ),
              ),
            ),
          ),
        ],
      ),
      body: AsyncListView<RoundDto>(
        value: rounds,
        emptyMessage: 'This season has no rounds yet.',
        onRetry: () => ref.invalidate(seasonRoundsProvider(seasonId)),
        itemBuilder: (context, round) => ListTile(
          key: Key('rounds.item.${round.id}'),
          leading: CircleAvatar(child: Text('${round.sequence}')),
          title: Text('Round ${round.sequence}'),
          subtitle: Text(
            '${roundStatusLabel(round.status)} · '
            'Deadline ${_formatDeadline(round.predictionDeadline)}',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => RoundFixturesScreen(roundId: round.id),
            ),
          ),
        ),
      ),
    );
  }
}

/// Humanises a round lifecycle status token.
String roundStatusLabel(String token) => switch (token) {
  'open' => 'Open for predictions',
  'locked' => 'Locked',
  'scored' => 'Scored',
  _ => token,
};

/// Renders the ISO-8601 UTC deadline compactly (date + minute, UTC), falling
/// back to the raw value if it cannot be parsed — a display concern only, never
/// a data mutation.
String _formatDeadline(String iso) {
  final parsed = DateTime.tryParse(iso);
  if (parsed == null) return iso;
  final utc = parsed.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${utc.year}-${two(utc.month)}-${two(utc.day)} '
      '${two(utc.hour)}:${two(utc.minute)} UTC';
}
