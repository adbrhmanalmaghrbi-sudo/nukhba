/// The ONE and ONLY place `apps/mobile` touches `package:http`.
///
/// `api_client`'s [ApiTransport] requires an injected `http.Client` (so it can
/// be driven by a `MockClient` in its own tests). This file constructs the
/// platform-default client and hands it to `api_client`; it makes NO request
/// itself. Every actual HTTP call is issued inside `api_client`, honouring the
/// "no HTTP in `apps/mobile`" rule (Flutter App phase constraint / ADR-002
/// §2.8) — this is dependency injection of a transport, not networking logic.
library;

import 'package:http/http.dart' as http;

/// Creates the platform-default [http.Client].
///
/// On native platforms this is the `dart:io`-backed client; on web it is the
/// browser `fetch`-backed client — `package:http` selects the right one. The
/// caller owns the returned client's lifecycle (it is closed when the owning
/// provider is disposed).
http.Client createHttpClient() => http.Client();
