/// The root application widget.
///
/// A single responsive `MaterialApp` (Flutter App phase decision #2: one
/// codebase for PWA + Android + iOS) whose home is the [SessionGate], so the
/// very first frame is driven by the authentication session state. No routing
/// table is declared here — v1 routing is the session gate's job (see
/// `session_gate.dart`); URL-addressable routes arrive with the later
/// multi-screen slices.
///
/// The visual identity is centralized in [AppTheme] (the "Midnight Pitch"
/// design system); every screen inherits it through Theme.of(context).
library;

import 'package:flutter/material.dart';

import 'core/theme/app_theme.dart';
import 'features/auth/session_gate.dart';

/// The Nukhba client application shell.
class NukhbaApp extends StatelessWidget {
  /// Creates the app shell.
  const NukhbaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nukhba',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      home: const SessionGate(),
    );
  }
}
