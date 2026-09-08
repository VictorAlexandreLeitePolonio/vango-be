import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../core/constants/app_assets.dart';
import '../../../core/routes/app_routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../shared/widgets/vango_button.dart';
import '../../../shared/widgets/vango_logo.dart';

/// Welcome / onboarding screen.
///
/// First screen of the app: logo, illustration, value proposition,
/// and action buttons for Login and Register.
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _animController;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _animController,
        curve: const Interval(0.0, 0.5, curve: Curves.easeOut),
      ),
    );

    _slideAnimation =
        Tween<Offset>(begin: const Offset(0, 0.15), end: Offset.zero).animate(
          CurvedAnimation(
            parent: _animController,
            curve: const Interval(0.3, 1.0, curve: Curves.easeOutCubic),
          ),
        );

    _animController.forward();
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          // ── Top: gradient + logo + illustration ─────────────
          Expanded(
            flex: 55,
            child: Container(
              width: double.infinity,
              decoration: const BoxDecoration(
                gradient: AppColors.backgroundGradient,
              ),
              child: SafeArea(
                bottom: false,
                child: FadeTransition(
                  opacity: _fadeAnimation,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox(height: 16),
                      const VanGoLogo(size: VanGoLogoSize.large),
                      const SizedBox(height: 24),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 40),
                          child: SvgPicture.asset(
                            AppAssets.onboardingIllustration,
                            fit: BoxFit.contain,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // ── Bottom: white card with text and buttons ────────
          Expanded(
            flex: 45,
            child: SlideTransition(
              position: _slideAnimation,
              child: FadeTransition(
                opacity: _fadeAnimation,
                child: Container(
                  width: double.infinity,
                  decoration: const BoxDecoration(
                    color: AppColors.cardBackground,
                    borderRadius: BorderRadius.vertical(
                      top: Radius.circular(32),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.shadowMedium,
                        blurRadius: 24,
                        offset: Offset(0, -4),
                      ),
                    ],
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(28, 36, 28, 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Text(
                          'Safe and organized\nschool transport',
                          textAlign: TextAlign.center,
                          style: AppTextStyles.heading2,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Connect with fleets, track trips,\nand gain peace of mind',
                          textAlign: TextAlign.center,
                          style: AppTextStyles.subtitle,
                        ),
                        const Spacer(),
                        VanGoButton(
                          text: 'Sign In',
                          onPressed: () {
                            Navigator.pushNamed(context, AppRoutes.login);
                          },
                        ),
                        const SizedBox(height: 14),
                        VanGoButton(
                          text: 'Create Account',
                          isOutlined: true,
                          onPressed: () {
                            Navigator.pushNamed(context, AppRoutes.register);
                          },
                        ),
                        const SizedBox(height: 16),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
