import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/constants/app_assets.dart';
import '../../core/theme/app_colors.dart';

/// Reusable VanGo logo widget.
///
/// Combines the SVG icon (van) with the "VanGo" brand text and supports
/// different sizes via [size]: `small`, `medium`, `large`.
class VanGoLogo extends StatelessWidget {
  const VanGoLogo({
    super.key,
    this.size = VanGoLogoSize.medium,
    this.showText = true,
    this.color,
  });

  final VanGoLogoSize size;
  final bool showText;
  final Color? color;

  double get _svgHeight {
    switch (size) {
      case VanGoLogoSize.small:
        return 36;
      case VanGoLogoSize.medium:
        return 52;
      case VanGoLogoSize.large:
        return 72;
    }
  }

  double get _fontSize {
    switch (size) {
      case VanGoLogoSize.small:
        return 22;
      case VanGoLogoSize.medium:
        return 32;
      case VanGoLogoSize.large:
        return 44;
    }
  }

  @override
  Widget build(BuildContext context) {
    // When showText is false, just render a small van icon fallback
    if (!showText) {
      return SvgPicture.asset(
        AppAssets.logoVango,
        height: _svgHeight,
        fit: BoxFit.contain,
        semanticsLabel: 'Logo VanGo',
      );
    }

    // Full logo with SVG (icon + text built-in)
    return SvgPicture.asset(
      AppAssets.logoVango,
      height: _svgHeight,
      fit: BoxFit.contain,
      semanticsLabel: 'Logo VanGo',
      placeholderBuilder: (_) =>
          _FallbackLogo(fontSize: _fontSize, color: color),
    );
  }
}

/// Fallback logo when the SVG is not loaded or unavailable.
class _FallbackLogo extends StatelessWidget {
  const _FallbackLogo({required this.fontSize, this.color});

  final double fontSize;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      shaderCallback: (bounds) =>
          AppColors.primaryGradient.createShader(bounds),
      child: Text(
        'VanGo',
        style: GoogleFonts.poppins(
          fontSize: fontSize,
          fontWeight: FontWeight.bold,
          color: color ?? Colors.white,
        ),
      ),
    );
  }
}

enum VanGoLogoSize { small, medium, large }
