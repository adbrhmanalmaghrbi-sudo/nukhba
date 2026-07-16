/// Browse level 4 — a round's fixtures (`GET /rounds/{id}` for the header +
/// `GET /rounds/{id}/fixtures` for the list).
///
/// The deepest hop of the browse navigation. Two reads compose here:
///   * `roundDetailProvider(roundId)` — the round header (sequence / status /
///     deadline / ruleset version). A missing round is `Err(invariant,
///     code: competition.round_not_found)`, rendered as a "not found" message.
///   * `roundFixturesProvider(roundId)` — the fixture links in display order. A
///     round with no fixtures (or one that does not exist) is a *legitimate*
///     empty list.
///
/// Browse-only: fixtures are shown as their stable ids in presentation order
/// (the fixture aggregate carries no competition ref — Axiom 3 — and the browse
/// contract exposes only the round↔fixture link). No prediction/submission
/// affordance appears here; Prediction is the next, separate screen.
library;

import 'package:contracts/contracts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../prediction/prediction_screen.dart';
import 'competition_providers.dart';
import 'season_rounds_screen.dart' show roundStatusLabel;
import 'widgets/async_list_view.dart';

/// The fixture-list screen for a single round.
class RoundFixturesScreen extends ConsumerWidget {
  /// Creates the fixtures screen for [roundId].
  const RoundFixturesScreen({required this.roundId, super.key});

  /// The round whose fixtures (and header) are shown.
  final String roundId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final round = ref.watch(roundDetailProvider(roundId));
    final fixtures = ref.watch(roundFixturesProvider(roundId));
    return Scaffold(
      appBar: AppBar(title: const Text('Round', key: Key('fixtures.title'))),
      body: Column(
        children: <Widget>[
          // The round header. A not-found round surfaces here (the fixtures
          // list below would otherwise just be a legitimate empty list).
          AsyncObjectView<RoundDto>(
            value: round,
            onRetry: () => ref.invalidate(roundDetailProvider(roundId)),
            builder: (context, r) => _RoundHeader(round: r),
          ),
          const Divider(height: 1),
          Expanded(
            child: AsyncListView<RoundFixtureDto>(
              value: fixtures,
              emptyMessage: 'This round has no fixtures yet.',
              onRetry: () => ref.invalidate(roundFixturesProvider(roundId)),
              itemBuilder: (context, fixture) => ListTile(
                key: Key('fixtures.item.${fixture.fixtureId}'),
                leading: CircleAvatar(
                  child: Text('${fixture.displayOrder + 1}'),
                ),
                title: Text('Fixture ${fixture.fixtureId}'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A compact header describing the round the fixtures belong to.
class _RoundHeader extends StatelessWidget {
  const _RoundHeader({required this.round});

  final RoundDto round;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const Key('fixtures.roundHeader'),
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      color: scheme.surfaceContainerHighest,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Round ${round.sequence}',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(
            '${roundStatusLabel(round.status)} · Rules v${round.rulesetVersion}',
          ),
          // Single, additive integration point into the Prediction (submit)
          // screen. Offered only while the round is open for predictions; a
          // locked/scored round shows no submit affordance here (the Prediction
          // screen would itself present a read-only "closed" notice). This is a
          // pure navigation push — no browse logic changes.
          if (round.status == 'open') ...<Widget>[
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const Key('fixtures.predict'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => PredictionScreen(roundId: round.id),
                ),
              ),
              icon: const Icon(Icons.sports_soccer),
              label: const Text('Predict this round'),
            ),
          ],
        ],
      ),
    );
  }
}
