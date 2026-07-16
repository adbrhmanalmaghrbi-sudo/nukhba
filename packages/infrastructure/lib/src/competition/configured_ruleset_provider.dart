import 'package:application/application.dart';
import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// [RulesetProvider] backed by a fixed, in-process table of default rulesets per
/// [FormatType].
///
/// This is the deliberate *placeholder-free* stand-in for the not-yet-built
/// Scoring context (Roadmap ADR: Scoring is a later phase; Application ADR,
/// Section 2.10). It is not a mock or a TODO — it is a real, complete adapter
/// that returns a genuine, versioned ruleset snapshot for the one format that
/// exists today ([FormatType.footballScoreline]). When the Scoring phase ships,
/// this adapter is replaced at the composition root by one backed by the Scoring
/// repository, with **no change** to the Competition use-cases that depend on
/// the [RulesetProvider] port — exactly the seam the ADRs mandate.
///
/// The returned snapshot is a real football-scoreline scoring rule set: it names
/// the format and specifies the points awarded for an exact scoreline and for a
/// correct outcome (result-only). Competition never interprets these keys; they
/// exist so the future Scoring engine has concrete, frozen rules to apply and so
/// the snapshot is meaningful the moment a round opens.
final class ConfiguredRulesetProvider implements RulesetProvider {
  /// Creates the provider. The default table is fixed and validated lazily on
  /// first use per format.
  const ConfiguredRulesetProvider();

  /// The current ruleset version shipped with this build. Bumping this (and the
  /// payload) is how the platform evolves default rules; already-frozen rounds
  /// keep their old snapshot version, which is the whole point of freezing.
  static const int _footballScorelineVersion = 1;

  @override
  Future<Result<RulesetSnapshot>> currentSnapshotFor(FormatType format) async {
    switch (format) {
      case FormatType.footballScoreline:
        return RulesetSnapshot.create(
          rulesetVersion: _footballScorelineVersion,
          payload: const {
            'format': 'football_scoreline',
            'points': {
              // Exact home/away scoreline predicted correctly.
              'exact_scoreline': 5,
              // Correct match outcome (home win / draw / away win) but wrong
              // exact scoreline.
              'correct_outcome': 2,
              // Neither outcome nor scoreline correct.
              'incorrect': 0,
            },
          },
        );
    }
  }
}
