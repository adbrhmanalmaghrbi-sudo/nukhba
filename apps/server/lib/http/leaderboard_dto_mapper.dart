import 'package:contracts/contracts.dart';
import 'package:domain/domain.dart';

/// Projects the domain [SeasonLeaderboard] aggregate onto the versioned wire
/// shape [SeasonLeaderboardDto] (API ADR §4), and one [LeaderboardEntry] onto
/// [LeaderboardEntryDto].
///
/// This mapping lives here, once, so the leaderboard read surface
/// (`GET /seasons/{id}/leaderboard`) shapes a standing identically everywhere.
///
/// Integrity boundary (Axioms 2/5): a leaderboard is a **server-produced read
/// value** — the rank, signed total, and entry count are echoed exactly as the
/// domain computed them from the append-only ledger projection; nothing here is
/// client-writable and there is no inverse (the client never sends a
/// leaderboard). The entries are echoed in the aggregate's already-ranked total
/// order (points desc, joinedAt asc, participant-id asc), so the display order
/// is fixed by the domain, not this mapper. Names a participant by id only; no
/// group reference travels on an entry (Axiom 4).
LeaderboardEntryDto leaderboardEntryToDto(LeaderboardEntry entry) {
  return LeaderboardEntryDto(
    rank: entry.rank,
    participantId: entry.participantId.value,
    totalPoints: entry.totalPoints,
    entryCount: entry.entryCount,
  );
}

/// Shapes a ranked [SeasonLeaderboard] into the whole-board read response
/// [SeasonLeaderboardDto], preserving the aggregate's ranked entry order. An
/// empty [SeasonLeaderboard.entries] shapes an empty `entries` array — a
/// legitimate empty board (a season with no participants), never an error.
Map<String, Object?> seasonLeaderboardToJson(SeasonLeaderboard leaderboard) {
  return SeasonLeaderboardDto(
    seasonId: leaderboard.seasonId.value,
    entries: [
      for (final entry in leaderboard.entries) leaderboardEntryToDto(entry),
    ],
  ).toJson();
}
