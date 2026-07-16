/// Thin, typed HTTP client for the Nukhba `apps/server` use-case API.
///
/// This is the **public** entry point of the package — the only import
/// `apps/mobile` (or any other consumer) needs:
///
/// ```dart
/// import 'package:api_client/api_client.dart';
/// ```
///
/// Consumers construct one [ApiTransport] (with a base [Uri], an injected
/// `http.Client`, and a [TokenProvider]) and then build the domain clients over
/// it — [AuthApi], [CompetitionApi], [PredictionApi], [LeaderboardsApi]. Every
/// client method is total: it returns a `Result<T>` (`shared`) and never throws;
/// failures arrive as the project-wide typed `AppError`.
///
/// Dependency boundary (ADR-002 §2.8, enforced by `tooling/import_lint`):
/// `api_client -> {contracts, shared}` only. It carries the versioned
/// `contracts` DTOs over the wire and reports failures as `shared`'s
/// `Result`/`AppError`; it never depends on `domain`, `application`,
/// `infrastructure`, or `server`. `apps/mobile` depends on this package
/// read-only.
///
/// The `Result`/`AppError`/`ErrorKind` types a caller branches on come from
/// `package:shared/shared.dart`, and the DTO shapes from
/// `package:contracts/contracts.dart`; both are already public packages, so
/// this barrel does not re-export them (a consumer imports them directly,
/// exactly as the server layer does).
library;

export 'src/api_error.dart'
    show
        apiErrorMalformedResponse,
        apiErrorNetworkUnreachable,
        apiErrorUnexpectedStatus;
export 'src/api_transport.dart' show ApiTransport, TokenProvider;
export 'src/auth_api.dart' show AuthApi;
export 'src/competition_api.dart' show CompetitionApi;
export 'src/leaderboards_api.dart' show LeaderboardsApi;
export 'src/prediction_api.dart' show PredictionApi;
