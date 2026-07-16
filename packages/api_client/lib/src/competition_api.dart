import 'package:api_client/src/api_transport.dart';
import 'package:contracts/contracts.dart';
import 'package:shared/shared.dart';

/// Typed client for the Competition browse surface of `apps/server`.
///
/// Wraps exactly the read routes that exist today, verbatim — no invented path.
/// The four hops of the browse navigation competition -> season -> round ->
/// fixtures are all reachable now that the FA-1 season/round scope closure
/// (2026-07-13) added the two middle-hop GET branches:
///   * `GET /competitions`               -> `List<CompetitionDto>`
///     (`routes/competitions/index.dart` GET branch, public catalogue)
///   * `GET /competitions/{id}`          -> [CompetitionDto]
///     (`routes/competitions/[id]/index.dart`; `404 competition.not_found`)
///   * `GET /competitions/{id}/seasons`  -> `List<SeasonDto>`
///     (`routes/competitions/[id]/seasons/index.dart` GET branch, label order;
///     an absent competition is a legitimate empty array — no existence oracle)
///   * `GET /seasons/{id}/rounds`        -> `List<RoundDto>`
///     (`routes/seasons/[id]/rounds/index.dart` GET branch, sequence order;
///     an absent season is a legitimate empty array — no existence oracle)
///   * `GET /rounds/{id}`                -> [RoundDto]
///     (`routes/rounds/[id]/index.dart`; `404 competition.round_not_found`)
///   * `GET /rounds/{id}/fixtures`       -> `List<RoundFixtureDto>`
///     (`routes/rounds/[id]/fixtures/index.dart` GET branch, display order;
///     an absent round is a legitimate empty array — no existence oracle)
///
/// All routes are behind `bearerAuth`. Every method is a pure read (no side
/// effect), returns a typed [Result], and never throws.
final class CompetitionApi {
  /// Creates the Competition client over the shared [ApiTransport].
  const CompetitionApi(this._transport);

  final ApiTransport _transport;

  /// `GET /competitions` — the browsable public competition catalogue.
  ///
  /// An empty catalogue is a legitimate `Ok(<empty list>)`, never an error.
  Future<Result<List<CompetitionDto>>> listCompetitions() {
    return _transport.getList<CompetitionDto>(
      '/competitions',
      parseElement: CompetitionDto.fromJson,
    );
  }

  /// `GET /competitions/{id}` — a single competition.
  ///
  /// A missing competition is `Err(invariant, code: competition.not_found)`
  /// (the server returns a true `404` with that stable code); a malformed id is
  /// `Err(validation)`.
  Future<Result<CompetitionDto>> getCompetition(String competitionId) {
    return _transport.getObject<CompetitionDto>(
      '/competitions/$competitionId',
      parse: CompetitionDto.fromJson,
    );
  }

  /// `GET /competitions/{id}/seasons` — the competition's seasons, label order.
  ///
  /// The first middle hop of the browse navigation. A competition with no
  /// seasons — or one that does not exist — is a legitimate `Ok(<empty list>)`
  /// (the server reveals no existence oracle on this browse read).
  Future<Result<List<SeasonDto>>> listCompetitionSeasons(String competitionId) {
    return _transport.getList<SeasonDto>(
      '/competitions/$competitionId/seasons',
      parseElement: SeasonDto.fromJson,
    );
  }

  /// `GET /seasons/{id}/rounds` — the season's rounds, 1-based sequence order.
  ///
  /// The second middle hop of the browse navigation. A season with no rounds —
  /// or one that does not exist — is a legitimate `Ok(<empty list>)` (no
  /// existence oracle). Each [RoundDto] exposes only the ruleset *version*,
  /// never the opaque frozen snapshot.
  Future<Result<List<RoundDto>>> listSeasonRounds(String seasonId) {
    return _transport.getList<RoundDto>(
      '/seasons/$seasonId/rounds',
      parseElement: RoundDto.fromJson,
    );
  }

  /// `GET /rounds/{id}` — a single round (status + deadline + ruleset version).
  ///
  /// A missing round is `Err(invariant, code: competition.round_not_found)`
  /// (true `404`); a malformed id is `Err(validation)`. The opaque frozen
  /// ruleset snapshot is never exposed — only [RoundDto.rulesetVersion].
  Future<Result<RoundDto>> getRound(String roundId) {
    return _transport.getObject<RoundDto>(
      '/rounds/$roundId',
      parse: RoundDto.fromJson,
    );
  }

  /// `GET /rounds/{id}/fixtures` — the round's fixtures in display order.
  ///
  /// A round with no linked fixtures — or one that does not exist — is a
  /// legitimate `Ok(<empty list>)` (the server reveals no existence oracle on
  /// this browse read).
  Future<Result<List<RoundFixtureDto>>> listRoundFixtures(String roundId) {
    return _transport.getList<RoundFixtureDto>(
      '/rounds/$roundId/fixtures',
      parseElement: RoundFixtureDto.fromJson,
    );
  }
}
