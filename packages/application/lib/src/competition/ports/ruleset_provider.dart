import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// Port that supplies the *current* ruleset to freeze onto a round at open time
/// (Application ADR, Section 2.10: Scoring owns rules-as-data; Competition
/// snapshots them).
///
/// The authoritative, editable ruleset lives in the Scoring context — a later
/// phase (Roadmap ADR). Competition must not reach into Scoring's storage or
/// invent scoring semantics; it only needs "give me the ruleset that governs a
/// [format] right now, as an immutable snapshot" at the instant a round opens.
/// This port is that seam: today an Infrastructure adapter supplies a
/// configured default per format; when Scoring ships, the same port is backed by
/// the Scoring repository with **no change to Competition**.
///
/// Contract for implementations:
/// * MUST return a [RulesetSnapshot] already frozen (deep-immutable) via
///   `RulesetSnapshot.create`.
/// * MUST return an [ErrorKind.invariant] error when no ruleset is defined for
///   the requested [format] (a round cannot open without rules).
/// * MUST map infrastructure failures to [ErrorKind.transient]; MUST NOT throw.
abstract interface class RulesetProvider {
  /// Returns the current ruleset snapshot to freeze for a round of the given
  /// competition [format].
  Future<Result<RulesetSnapshot>> currentSnapshotFor(FormatType format);
}
