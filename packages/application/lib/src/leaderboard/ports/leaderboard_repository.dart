import 'package:domain/domain.dart';
import 'package:shared/shared.dart';

/// Read port for the **Leaderboards** projection (Application ADR §9: use-cases
/// depend on repository interfaces, Infrastructure implements them).
///
/// A leaderboard is a **read-side projection** over the ratified append-only
/// ledger (Axiom 5; Leaderboards architecture decision in project-context §2) —
/// never a second source of truth for points. This port produces, for a season,
/// one **unranked** [LeaderboardEntry] per season participant: their signed
/// point total (the SUM of their ledger `amount`s — equal to their
/// `LedgerBalance.balance`, so a `correction` is already netted in) plus the
/// count of movements summed and their `joinedAt` tie-break key. The ordering
/// and standard-competition ("1224") ranking are applied by the pure domain
/// [SeasonLeaderboard.rank] in the use-case, NOT here — so the ranking rule is
/// framework-free and identical whoever runs the query.
///
/// Backed by `PostgresLeaderboardRepository`, which reads the season-scoped
/// projection VIEW `leaderboard.season_standings` (migration
/// `0006_leaderboard.sql`): a join of `ledger.point_entries` →
/// `competition.participants` → `competition.rounds`, `SUM(amount)` grouped by
/// participant, LEFT-joined so an enrolled-but-never-credited participant still
/// appears with a zero total. The interface speaks in the domain
/// [LeaderboardEntry] and typed ids — never in rows or SQL.
///
/// General contract for every method (Application ADR §2):
/// * MUST NOT throw — every outcome is a typed [Result].
/// * MUST map infrastructure failures to [ErrorKind.transient].
/// * MUST return every ACTIVE/WITHDRAWN participant of the season exactly once
///   (a withdrawn participant keeps their competitive record — Axiom 5 — so they
///   remain on the historical board); a participant with no ledger movements
///   yet appears with `totalPoints == 0`, `entryCount == 0`.
abstract interface class LeaderboardRepository {
  /// Returns the **unranked** projection entries for [seasonId] — one per season
  /// participant, each carrying their signed total, movement count, and
  /// `joinedAt` tie-break key. The list order is unspecified (the use-case sorts
  /// and ranks it via [SeasonLeaderboard.rank]); an empty list means the season
  /// has no participants (a legitimate empty board, not an error).
  Future<Result<List<LeaderboardEntry>>> seasonStandings(SeasonId seasonId);
}
