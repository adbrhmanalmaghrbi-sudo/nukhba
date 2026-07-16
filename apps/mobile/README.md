# mobile — Nukhba Platform Flutter client

One responsive Flutter codebase targeting **PWA + Android + iOS** (Flutter App
phase decision #2). Core v1 scope: **Auth**, Competition (browse), Prediction
(submit), Leaderboards (view). All networking goes through the ratified
`packages/api_client` use-case API over `apps/server`; the client performs **no
HTTP itself** and never writes directly to any Tier-1 Supabase table
(ADR-002 §2.2/§2.8).

## Layout

```
lib/
  main.dart                     ProviderScope + app entry
  app.dart                      MaterialApp shell; home = SessionGate
  core/
    config/app_config.dart      API base URL from --dart-define
    auth/token_store.dart       TokenStore seam (secure + in-memory impls)
    error/error_presenter.dart  AppError -> user copy (single mapping)
    network/http_client.dart    the ONLY package:http touch-point (DI only)
    providers.dart              Riverpod wiring: config, token store,
                                ApiTransport, AuthApi  (@riverpod)
  features/
    auth/
      session_state.dart        sealed SessionState (unknown/unauth/authing/
                                authenticated/failed)
      session_controller.dart   @riverpod async controller: restore/signIn/
                                signOut/retry via AuthApi + TokenStore
      sign_in_screen.dart       token entry -> signIn(); error banner
      account_screen.dart       renders GET /me principal + sign-out
      session_gate.dart         state-driven router (no routing package in v1)
test/
  support/auth_harness.dart     MockClient transport + InMemoryTokenStore
  features/auth/*_test.dart      controller unit tests + gate widget tests
```

## Sign-in mechanism (v1, contract-faithful)

The backend has no password/login route — Supabase mints the access token and
the server only **verifies** it (Security ADR §2). The one identity route is
`GET /me` behind `bearerAuth`. So the client "signs in" by accepting an access
token, persisting it via `TokenStore`, then validating it with `GET /me`:
`200` → authenticated (principal held); `401` → the token is cleared and a
failure is shown; a transient/network failure keeps the token so the user can
retry. A later, separately-ratified Supabase client flow plugs into the same
`SessionController.signIn(token)` seam without changing the UI or controller.

## Build / run / test (requires the ratified Flutter SDK 3.44.0, `.fvmrc`)

Riverpod uses code generation; the `*.g.dart` glue is produced by
`build_runner` (git-ignored, never hand-edited):

```bash
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # generates *.g.dart
flutter analyze
flutter test
flutter run --dart-define=NUKHBA_API_BASE_URL=https://api.nukhba.example
```

The sandbox has no Flutter toolchain, so in-repo verification is
by-construction against the exact `api_client` / `contracts` / `shared` public
surfaces and the version-checked libraries in `project-context.md` §3.
