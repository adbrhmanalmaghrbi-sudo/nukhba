library;

import 'package:flutter/material.dart';

abstract final class AppColors {
  // ===== Backgrounds (depth layers) =====
  static const Color background = Color(0xFF0A1420);
  static const Color backgroundElevated = Color(0xFF0F1D2E);
  static const Color surface = Color(0xFF15263B);
  static const Color surfaceElevated = Color(0xFF1D3350);
  static const Color surfaceHigh = Color(0xFF264566);

  static const Color primary = Color(0xFF12D18E);
  static const Color primaryDark = Color(0xFF0EA372);
  static const Color primaryLight = Color(0xFF4EEBB4);

  static const Color gold = Color(0xFFF5B841);
  static const Color goldDark = Color(0xFFD99A24);

  static const Color silver = Color(0xFFC7D0DB);
  static const Color onSilver = Color(0xFF1B2430);
  static const Color bronze = Color(0xFFCD7F32);
  static const Color onBronze = Color(0xFF2A1608);

  static const Color success = Color(0xFF12D18E);
  static const Color warning = Color(0xFFF5B841);
  static const Color error = Color(0xFFFF5C6C);
  static const Color errorContainer = Color(0xFF3D1A22);
  static const Color info = Color(0xFF4EA8DE);

  static const Color textPrimary = Color(0xFFF5F8FC);
  static const Color textSecondary = Color(0xFFA8B7C9);
  static const Color textMuted = Color(0xFF667790);
  static const Color onPrimary = Color(0xFF04231A);
  static const Color onGold = Color(0xFF2E1F02);
  static const Color onError = Color(0xFF2A0A0E);

  static const Color border = Color(0x1AFFFFFF);

  static const LinearGradient backgroundGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [backgroundElevated, background],
  );

  static const LinearGradient primaryGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [primaryLight, primary],
  );

  static const LinearGradient goldGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [gold, goldDark],
  );
}
