import 'package:flutter/material.dart';

/// Design system — VanGo color palette.
///
/// Warm orange (#F7931E) with a smooth gradient to gold (#FDB813).
/// Light background (white/cream) with dark text.
class AppColors {
  AppColors._();

  // ── Primary colors ──────────────────────────────────────────
  static const Color primaryOrange = Color(0xFFF7931E);
  static const Color primaryGold = Color(0xFFFDB813);
  static const Color primaryOrangeDark = Color(0xFFE07B0A);

  // ── Main gradient ───────────────────────────────────────────
  static const LinearGradient primaryGradient = LinearGradient(
    colors: [primaryOrange, primaryGold],
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
  );

  static const LinearGradient backgroundGradient = LinearGradient(
    colors: [primaryOrange, primaryGold],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  // ── Backgrounds ─────────────────────────────────────────────
  static const Color backgroundWhite = Color(0xFFFAFAFA);
  static const Color backgroundCream = Color(0xFFFFF8F0);
  static const Color cardBackground = Color(0xFFFFFFFF);

  // ── Typography ──────────────────────────────────────────────
  static const Color textDark = Color(0xFF1A1A2E);
  static const Color textMuted = Color(0xFF6B7280);
  static const Color textLight = Color(0xFFFFFFFF);

  // ── Inputs ──────────────────────────────────────────────────
  static const Color inputBorder = Color(0xFFE5E7EB);
  static const Color inputFocusBorder = Color(0xFFF7931E);
  static const Color inputBackground = Color(0xFFF9FAFB);

  // ── Feedback ────────────────────────────────────────────────
  static const Color errorRed = Color(0xFFEF4444);
  static const Color successGreen = Color(0xFF10B981);
  static const Color warningYellow = Color(0xFFF59E0B);

  // ── Shadows ─────────────────────────────────────────────────
  static const Color shadowLight = Color(0x0D000000);
  static const Color shadowMedium = Color(0x1A000000);
}
