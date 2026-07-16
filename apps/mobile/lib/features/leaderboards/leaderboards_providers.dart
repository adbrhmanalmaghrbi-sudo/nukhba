/// The Leaderboards **view** state — an annotation-based Riverpod provider that
/// exposes a season's ranked standings as an async value the UI watches.
///
/// ## Scope (Flutter App phase, Core decision #1 — view-only)
/// This is a strictly read-only surface: it renders one season's leaderboard
/// (`GET /seasons/{id}/leaderboard`). It builds **no** points/ranking logic — a
/// leaderboard is a server-produced projection over the append-only ledger
/// (Axiom 5), so the client only displays the ranks/totals the server computed
/// and never submits or derives a point value (Axiom 2). Group/global
/// leaderboards are OUT of Core scope (Groups deferred to v1.1) and are not
/// wrapped here.
///
/// ## Wiring
/// All networking is the ratified `api_client` via [LeaderboardsApi] (obtained
/// from `core/providers.dart`'s `leaderboardsApiProvider`); `apps/mobile`
/// performs no HTTP itself. The provider calls exactly the one `LeaderboardsApi`
/// method and maps its typed `Result`:
///   * `Ok(SeasonLeaderboardDto)` → the provider's data value. An **empty**
///     `entries` list is a *legitimate* success (a season with no participants),
///     never an error — the UI shows an "empty" affordance, not a failure;
///   * `Err(error)` → the provider throws the typed [AppError], so the watching
///     widget receives it as `AsyncError` and renders it through
///     `ErrorPresenter` (network / `leaderboard.not_a_participant` / validation,
///     all uniformly, never branching on a raw code).
///
/// Throwing the `AppError` (rather than surfacing a sealed union) keeps this a
/// idiomatic `FutureProvider` while preserving the *typed* error: the UI catches
/// `AppError` off `AsyncValue.error`. A non-member is refused
/// `401 leaderboard.not_a_participant`, surfaced here as
/// `Err(authorization, code: leaderboard.not_a_participant)` and presented as a
/// tailored "not a member of this season" message by `ErrorPresenter` — the
/// board is not a season-existence oracle beyond membership (Security ADR §2).
library;

import 'package:api_client/api_client.dart';
import 'package:contracts/contracts.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared/shared.dart';

import '../../core/providers.dart';

part 'leaderboards_providers.g.dart';

/// Unwraps a typed [Result] into a plain value for a `FutureProvider`, throwing
/// the typed [AppError] on failure so the watching widget sees `AsyncError`
/// carrying an [AppError] (rendered via `ErrorPresenter`).
T _unwrap<T>(Result<T> result) => switch (result) {
  Ok<T>(:final value) => value,
  Err<T>(:final error) => throw error,
};

/// `GET /seasons/{id}/leaderboard` — a season's ranked standings.
///
/// A season with no participants resolves to a [SeasonLeaderboardDto] whose
/// `entries` list is empty — a *legitimate* success shown as an "empty"
/// affordance, never an error. A non-member is refused
/// `Err(authorization, code: leaderboard.not_a_participant)`, rethrown here so
/// the screen renders the tailored message via `ErrorPresenter`.
@riverpod
Future<SeasonLeaderboardDto> seasonLeaderboard(Ref ref, String seasonId) async {
  final api = ref.watch(leaderboardsApiProvider);
  return _unwrap(await api.seasonLeaderboard(seasonId));
}
