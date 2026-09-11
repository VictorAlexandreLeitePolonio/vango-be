import 'package:flutter/material.dart';

/// Design system — VanGo color palette.
///
/// Warm amber accents over cream surfaces and deep navy text.
class AppColors {
  AppColors._();

  // ── Primary colors ──────────────────────────────────────────
  static const Color primaryOrange = Color(0xFFF28C28);
  static const Color primaryGold = Color(0xFFFFC857);
  static const Color primaryOrangeDark = Color(0xFFB5540A);
  static const Color primaryNavy = Color(0xFF10223B);
  static const Color primaryNavyLight = Color(0xFF183553);

  // ── Main gradient ───────────────────────────────────────────
  static const LinearGradient primaryGradient = LinearGradient(
    colors: [primaryOrange, primaryGold],
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
  );

  static const LinearGradient backgroundGradient = LinearGradient(
    colors: [primaryNavy, primaryNavyLight],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  // ── Backgrounds ─────────────────────────────────────────────
  static const Color backgroundWhite = Color(0xFFFFFBF4);
  static const Color backgroundCream = Color(0xFFFFF7EA);
  static const Color cardBackground = Color(0xFFFFFFFF);

  // ── Typography ──────────────────────────────────────────────
  static const Color textDark = primaryNavy;
  static const Color textMuted = Color(0xFF546476);
  static const Color textLight = Color(0xFFFFFFFF);

  // ── Inputs ──────────────────────────────────────────────────
  static const Color inputBorder = Color(0xFFDDE4EA);
  static const Color inputFocusBorder = primaryOrangeDark;
  static const Color inputBackground = Color(0xFFFFFFFF);

  // ── Feedback ────────────────────────────────────────────────
  static const Color errorRed = Color(0xFFEF4444);
  static const Color successGreen = Color(0xFF1F8A70);
  static const Color warningYellow = Color(0xFFF59E0B);

  // ── Shadows ─────────────────────────────────────────────────
  static const Color shadowLight = Color(0x0D10223B);
  static const Color shadowMedium = Color(0x1A10223B);
}
