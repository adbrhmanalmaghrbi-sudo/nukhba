import 'package:api_client/src/api_transport.dart';
import 'package:contracts/contracts.dart';
import 'package:shared/shared.dart';

/// Typed client for the Leaderboards surface of `apps/server`.
///
/// Wraps exactly the one season-leaderboard read route that exists today,
/// verbatim — no invented path:
///   * `GET /seasons/{id}/leaderboard` -> [SeasonLeaderboardDto]
///     (`routes/seasons/[id]/leaderboard/index.dart`).
///
/// A leaderboard is a **read-only** projection over the append-only ledger
/// (Axiom 5): the server computes every rank and total; the client never
/// submits or computes a point value, so this client is query-only (there is no
/// command DTO for a leaderboard — contracts `leaderboard_dto.dart`).
///
/// Visibility gate (server-side, `GetSeasonLeaderboard`): the standings are
/// visible only to a **member of the season** (any status — a withdrawn member
/// keeps their record and may still read the board they were part of). A
/// non-member is refused `401 leaderboard.not_a_participant`, which surfaces
/// here as `Err(authorization, code: leaderboard.not_a_participant)`; the board
/// is therefore not a season-existence oracle beyond membership (Security ADR
/// §2). There is NO admin gate — this is a read, not a points write (Axiom 2
/// governs writes).
///
/// The whole `/seasons` subtree is behind `bearerAuth`
/// (`routes/seasons/_middleware.dart`); an unauthenticated call is refused there
/// with `401`. Every method is a pure read (no side effect), returns a typed
/// [Result], and never throws.
///
/// Group leaderboards (`GET /groups/{id}/seasons/{seasonId}/leaderboard`) are
/// deliberately OUT of Core scope (project-context §4, Flutter App decision #1 —
/// Groups deferred to v1.1) and are NOT wrapped here.
final class LeaderboardsApi {
  /// Creates the Leaderboards client over the shared [ApiTransport].
  const LeaderboardsApi(this._transport);

  final ApiTransport _transport;

  /// `GET /seasons/{id}/leaderboard` — a season's ranked standings.
  ///
  /// Returns:
  ///   * `Ok(SeasonLeaderboardDto)` on `200` — an **empty** `entries` list is a
  ///     legitimate result (a season with no participants), never an error;
  ///   * `Err(authorization, code: leaderboard.not_a_participant)` on `401`
  ///     when the caller is not a member of the season;
  ///   * `Err(validation)` if [seasonId] is malformed (server `400`);
  ///   * `Err(transient)` on `503` or a network failure (retryable);
  ///   * `Err(validation, code: api_client.malformed_response)` if the `200`
  ///     body is not a valid [SeasonLeaderboardDto].
  Future<Result<SeasonLeaderboardDto>> seasonLeaderboard(String seasonId) {
    return _transport.getObject<SeasonLeaderboardDto>(
      '/seasons/$seasonId/leaderboard',
      parse: SeasonLeaderboardDto.fromJson,
    );
  }
}
