import 'package:domain/src/competition/participant_id.dart';
import 'package:shared/shared.dart';

/// One participant's line on a season leaderboard — a **read-side projection**
/// value (Axiom 5: the leaderboard is a projection over the append-only ledger,
/// never a second source of truth for points; Database ADR: "balance is a
/// projection").
///
/// It names the [participantId] by id only (never the `Participant` entity) and
/// carries no group reference (Axiom 4: one score, ranked everywhere — the entry
/// reflects a total without a group binding). Its [totalPoints] is the signed
/// SUM of that participant's ledger `amount`s (so any `correction` entry is
/// already netted in — it equals the participant's own `LedgerBalance.balance`),
/// and [entryCount] records how many immutable ledger movements it sums (audit /
/// traceability — a total is always explainable by this many appends).
///
/// [rank] is the participant's **standard competition rank ("1224")** on the
/// board: equal [totalPoints] share a rank, and the next distinct total skips by
/// the number tied. It is assigned by [SeasonLeaderboard] over the fully ordered
/// entries — never computed by this value in isolation.
///
/// The tie-break keys ([joinedAt], then [participantId]) travel with the entry
/// so a leaderboard is a **total, reproducible order** even before ranks are
/// assigned: among equal totals the earlier joiner sorts first, then by id — a
/// deterministic rule, never arbitrary storage order.
///
/// Points here are a **server-computed read value** (Axiom 2: the client never
/// computes or submits a point amount). Pure and immutable; value-comparable by
/// all fields.
final class LeaderboardEntry {
  const LeaderboardEntry._({
    required this.participantId,
    required this.totalPoints,
    required this.entryCount,
    required this.joinedAt,
    required this.rank,
  });

  /// Builds an **unranked** entry from an aggregated ledger projection for one
  /// participant. The [rank] is left `0` (unassigned) — a meaningful rank exists
  /// only relative to the whole ordered board, so it is assigned later by
  /// [SeasonLeaderboard.rank]; constructing an entry in isolation with a
  /// fabricated rank would be a lie about a position that is not yet known.
  ///
  /// Enforced invariants (kept total — no exception escapes a query path):
  /// * [entryCount] must be non-negative (a count of immutable movements);
  /// * [joinedAt] must be UTC, so the tie-break ordering is unambiguous across
  ///   zones (the participant's stored `joinedAt` is already normalized to UTC).
  ///
  /// [totalPoints] is intentionally *unconstrained in sign*: it is a SUM that a
  /// `correction` entry may drive negative, exactly like `LedgerBalance.balance`
  /// (Axiom 5 — corrections net in). A participant enrolled but never credited
  /// projects `totalPoints == 0`, `entryCount == 0`.
  static Result<LeaderboardEntry> projected({
    required ParticipantId participantId,
    required int totalPoints,
    required int entryCount,
    required DateTime joinedAt,
  }) {
    if (entryCount < 0) {
      return const Result.err(
        AppError.invariant(
          'leaderboard.entry_count_negative',
          'A leaderboard entry cannot sum a negative number of movements',
        ),
      );
    }
    if (!joinedAt.isUtc) {
      return const Result.err(
        AppError.validation(
          'leaderboard.entry_joined_at_not_utc',
          'joinedAt must be provided in UTC',
        ),
      );
    }
    return Result.ok(
      LeaderboardEntry._(
        participantId: participantId,
        totalPoints: totalPoints,
        entryCount: entryCount,
        joinedAt: joinedAt,
        rank: _unassignedRank,
      ),
    );
  }

  /// The sentinel rank of an entry that has not yet been placed on a board.
  static const int _unassignedRank = 0;

  /// The participant this line belongs to (by id).
  final ParticipantId participantId;

  /// The signed SUM of the participant's ledger `amount`s — equals their
  /// `LedgerBalance.balance` (corrections already netted in — Axiom 5).
  final int totalPoints;

  /// How many immutable ledger movements contributed to [totalPoints] (audit).
  final int entryCount;

  /// When the participant joined the season (UTC) — the primary tie-break key
  /// among equal [totalPoints] (earlier joiner ranks first).
  final DateTime joinedAt;

  /// The participant's standard-competition ("1224") rank on the board, or `0`
  /// while unassigned (see [projected]). Assigned by [SeasonLeaderboard].
  final int rank;

  /// Whether this entry has been placed on a board (has a meaningful [rank]).
  bool get isRanked => rank != _unassignedRank;

  /// Returns a copy of this entry placed at [assignedRank] on a board.
  ///
  /// [assignedRank] must be a positive 1-based position — ranks start at 1;
  /// assigning `0` or a negative rank is an [ErrorKind.invariant] failure so a
  /// mis-built board can never silently ship an unplaced or nonsensical line.
  Result<LeaderboardEntry> withRank(int assignedRank) {
    if (assignedRank < 1) {
      return const Result.err(
        AppError.invariant(
          'leaderboard.rank_not_positive',
          'A leaderboard rank must be a positive 1-based position',
        ),
      );
    }
    return Result.ok(
      LeaderboardEntry._(
        participantId: participantId,
        totalPoints: totalPoints,
        entryCount: entryCount,
        joinedAt: joinedAt,
        rank: assignedRank,
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LeaderboardEntry &&
      other.participantId == participantId &&
      other.totalPoints == totalPoints &&
      other.entryCount == entryCount &&
      other.joinedAt == joinedAt &&
      other.rank == rank;

  @override
  int get hashCode =>
      Object.hash(participantId, totalPoints, entryCount, joinedAt, rank);

  @override
  String toString() =>
      'LeaderboardEntry(#$rank participant: ${participantId.value}, '
      'total: $totalPoints, entries: $entryCount)';
}
