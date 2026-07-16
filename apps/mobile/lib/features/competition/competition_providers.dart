/// The Competition **browse** state — annotation-based Riverpod providers that
/// expose the four read hops of the browse navigation as async values the UI
/// watches.
///
/// ## Scope (Flutter App phase, Core decision #1 — browse-only)
/// This is a strictly read-only surface: it renders the public competition
/// catalogue and lets the user drill competition → season → round → fixtures.
/// It builds **no** prediction/submission logic (Prediction is the next,
/// separate screen). Every hop is a pure read.
///
/// ## Wiring
/// All networking is the ratified `api_client` via [CompetitionApi] (obtained
/// from `core/providers.dart`'s `competitionApiProvider`); `apps/mobile`
/// performs no HTTP itself. Each provider calls exactly one `CompetitionApi`
/// method and maps its typed `Result`:
///   * `Ok(value)`  → the provider's data value (an empty list is a *legitimate*
///     success, never an error — the UI shows an "empty" affordance, not a
///     failure);
///   * `Err(error)` → the provider throws the typed [AppError], so the watching
///     widget receives it as `AsyncError` and renders it through
///     `ErrorPresenter` (network/authorization/"not found", all uniformly).
///
/// Throwing the `AppError` (rather than surfacing a sealed union) keeps these
/// providers idiomatic `FutureProvider`s while preserving the *typed* error: the
/// UI catches `AppError` off `AsyncValue.error` and never branches on a raw
/// exception. The two single-item reads (`getCompetition`/`getRound`) surface a
/// missing resource as an `Err(invariant, code: competition[.round]_not_found)`
/// exactly as [CompetitionApi] documents — the UI presents that as a "not found"
/// message via `ErrorPresenter`, distinct from an empty list.
library;

import 'package:api_client/api_client.dart';
import 'package:contracts/contracts.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared/shared.dart';

import '../../core/providers.dart';

part 'competition_providers.g.dart';

/// Unwraps a typed [Result] into a plain value for a `FutureProvider`, throwing
/// the typed [AppError] on failure so the watching widget sees `AsyncError`
/// carrying an [AppError] (rendered via `ErrorPresenter`).
T _unwrap<T>(Result<T> result) => switch (result) {
  Ok<T>(:final value) => value,
  Err<T>(:final error) => throw error,
};

/// `GET /competitions` — the browsable public competition catalogue.
///
/// An empty catalogue resolves to `Ok(<empty>)` and is surfaced here as an empty
/// list (a legitimate success): the list screen shows its "no competitions"
/// affordance, not an error.
@riverpod
Future<List<CompetitionDto>> competitionList(Ref ref) async {
  final api = ref.watch(competitionApiProvider);
  return _unwrap(await api.listCompetitions());
}

/// `GET /competitions/{id}` — a single competition by [competitionId].
///
/// A missing competition arrives as `Err(invariant,
/// code: competition.not_found)` and is rethrown here so the detail screen
/// renders a "not found" message (distinct from an empty child list).
@riverpod
Future<CompetitionDto> competitionDetail(Ref ref, String competitionId) async {
  final api = ref.watch(competitionApiProvider);
  return _unwrap(await api.getCompetition(competitionId));
}

/// `GET /competitions/{id}/seasons` — the competition's seasons (label order).
///
/// The first middle hop. A competition with no seasons — or one that does not
/// exist — resolves to a *legitimate* empty list (the browse read reveals no
/// existence oracle), shown as an "empty" affordance, never an error.
@riverpod
Future<List<SeasonDto>> competitionSeasons(
  Ref ref,
  String competitionId,
) async {
  final api = ref.watch(competitionApiProvider);
  return _unwrap(await api.listCompetitionSeasons(competitionId));
}

/// `GET /seasons/{id}/rounds` — the season's rounds (1-based sequence order).
///
/// The second middle hop. A season with no rounds — or one that does not exist —
/// resolves to a legitimate empty list (no existence oracle).
@riverpod
Future<List<RoundDto>> seasonRounds(Ref ref, String seasonId) async {
  final api = ref.watch(competitionApiProvider);
  return _unwrap(await api.listSeasonRounds(seasonId));
}

/// `GET /rounds/{id}` — a single round by [roundId].
///
/// A missing round arrives as `Err(invariant,
/// code: competition.round_not_found)` and is rethrown so the fixtures screen
/// renders a "not found" message. Only the ruleset *version* is ever exposed —
/// never the opaque frozen snapshot.
@riverpod
Future<RoundDto> roundDetail(Ref ref, String roundId) async {
  final api = ref.watch(competitionApiProvider);
  return _unwrap(await api.getRound(roundId));
}

/// `GET /rounds/{id}/fixtures` — the round's fixtures (display order).
///
/// The final hop. A round with no linked fixtures — or one that does not exist —
/// resolves to a legitimate empty list (no existence oracle).
@riverpod
Future<List<RoundFixtureDto>> roundFixtures(Ref ref, String roundId) async {
  final api = ref.watch(competitionApiProvider);
  return _unwrap(await api.listRoundFixtures(roundId));
}
