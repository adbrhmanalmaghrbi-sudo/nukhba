/// Application entry point.
///
/// Wraps the [NukhbaApp] shell in a Riverpod `ProviderScope` — the single
/// container that owns every provider (config, transport, token store, the
/// session controller). Production uses the providers exactly as declared in
/// `core/providers.dart` (a `SecureTokenStore`, the environment-derived
/// `AppConfig`); tests build their own `ProviderScope` with overrides.
///
/// No bootstrapping I/O happens here: the boot-time token restore is performed
/// lazily by `SessionController.build()` the first time the `SessionGate`
/// watches it, so `main` stays synchronous and side-effect-free beyond running
/// the app.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';

void main() {
  runApp(const ProviderScope(child: NukhbaApp()));
}
