/// Application-wide dependency providers (the composition seam for `apps/mobile`).
///
/// This file is the client's small equivalent of the server's `CompositionRoot`:
/// it constructs the ratified `api_client` transport + domain clients and the
/// platform `TokenStore`, and exposes them as Riverpod providers so feature
/// state (the session controller, and later Competition/Prediction/Leaderboard
/// controllers) can depend on them without knowing how they are built.
///
/// It performs NO HTTP and holds NO business logic — it only wires
/// already-built collaborators (Flutter App phase constraint / ADR-002 §2.8):
///   * [AppConfig] from compile-time environment (base API URL);
///   * the one `http.Client` (via `createHttpClient`, the sole `package:http`
///     touch-point in the app);
///   * [TokenStore] — `SecureTokenStore` in production; overridable with an
///     `InMemoryTokenStore` in tests via a ProviderScope override;
///   * an [ApiTransport] whose [TokenProvider] reads the current token from the
///     [TokenStore], so every `api_client` call is authenticated transparently;
///   * the typed domain clients ([AuthApi], [CompetitionApi], [PredictionApi],
///     [LeaderboardsApi]).
library;

import 'package:api_client/api_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'config/app_config.dart';
import 'auth/token_store.dart';
import 'network/http_client.dart';

part 'providers.g.dart';

/// The immutable runtime configuration, resolved once from the environment.
///
/// Overridden in tests (and in a custom bootstrap) by supplying a different
/// [AppConfig] through a `ProviderScope` override.
@Riverpod(keepAlive: true)
AppConfig appConfig(Ref ref) => AppConfig.fromEnvironment();

/// The platform-secure token store — the single owner of *where* the access
/// token lives on the client. Production wiring uses `flutter_secure_storage`;
/// tests override this provider with an [InMemoryTokenStore].
@Riverpod(keepAlive: true)
TokenStore tokenStore(Ref ref) =>
    const SecureTokenStore(FlutterSecureStorage());

/// The one shared [ApiTransport]. It owns the app's single `http.Client`
/// (closed when this provider is disposed) and reads the bearer token from the
/// [TokenStore] on every request via its [TokenProvider] — the app never
/// attaches a token by hand.
@Riverpod(keepAlive: true)
ApiTransport apiTransport(Ref ref) {
  final config = ref.watch(appConfigProvider);
  final store = ref.watch(tokenStoreProvider);
  final client = createHttpClient();
  ref.onDispose(client.close);
  return ApiTransport(
    baseUri: config.apiBaseUrl,
    httpClient: client,
    tokenProvider: store.read,
  );
}

/// The typed Auth (identity) client over the shared transport.
@Riverpod(keepAlive: true)
AuthApi authApi(Ref ref) => AuthApi(ref.watch(apiTransportProvider));

/// The typed Competition (browse) client over the shared transport.
///
/// Consumed read-only by the Competition browse feature (competition -> season
/// -> round -> fixtures). Like [authApi], it holds no state and performs no HTTP
/// of its own — it delegates every read to the shared [ApiTransport].
@Riverpod(keepAlive: true)
CompetitionApi competitionApi(Ref ref) =>
    CompetitionApi(ref.watch(apiTransportProvider));

/// The typed Prediction (submit) client over the shared transport.
///
/// Consumed by the Prediction feature (read the caller's own prediction for a
/// round, and submit/amend it). Like [authApi]/[competitionApi] it holds no
/// state and performs no HTTP of its own — it delegates every call to the
/// shared [ApiTransport], which attaches the bearer token. This is the ONLY
/// prediction write path the client has; there is no direct Supabase write
/// (ADR-002 §2.2/§2.8) — every submission goes through the server use-case API.
@Riverpod(keepAlive: true)
PredictionApi predictionApi(Ref ref) =>
    PredictionApi(ref.watch(apiTransportProvider));

/// The typed Leaderboards (view) client over the shared transport.
///
/// Consumed read-only by the Leaderboards feature (a season's ranked
/// standings). Like [authApi]/[competitionApi]/[predictionApi] it holds no
/// state and performs no HTTP of its own — it delegates the one leaderboard
/// read (`GET /seasons/{id}/leaderboard`) to the shared [ApiTransport], which
/// attaches the bearer token. A leaderboard is a read-only projection over the
/// append-only ledger (Axiom 5): the server computes every rank and total; the
/// client never submits or computes a point value, so this client is
/// query-only.
@Riverpod(keepAlive: true)
LeaderboardsApi leaderboardsApi(Ref ref) =>
    LeaderboardsApi(ref.watch(apiTransportProvider));
