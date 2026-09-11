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
      duration: const Duration(milliseconds: 260),
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
      backgroundColor: AppColors.backgroundCream,
      body: Column(
        children: [
          // ── Top: logo + illustration ────────────────────────────
          Expanded(
            child: SafeArea(
              bottom: false,
              child: FadeTransition(
                opacity: _fadeAnimation,
                child: Column(
                  children: [
                    const SizedBox(height: 16),
                    const VanGoLogo(
                      key: Key('welcomeLogo'),
                      size: VanGoLogoSize.large,
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 440),
                          child: AspectRatio(
                            aspectRatio: 1.2,
                            child: SvgPicture.asset(
                              AppAssets.onboardingIllustration,
                              key: const Key('onboardingBanner'),
                              width: double.infinity,
                              fit: BoxFit.contain,
                              semanticsLabel:
                                  'Van escolar conectando a escola ao destino '
                                  'por uma rota segura',
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                  ],
                ),
              ),
            ),
          ),

          // ── Bottom: white card with text and buttons ────────────
          Padding(
            padding: const EdgeInsets.only(bottom: 40),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: SlideTransition(
                  position: _slideAnimation,
                  child: FadeTransition(
                    opacity: _fadeAnimation,
                    child: Container(
                      key: const Key('welcomeActionCard'),
                      width: double.infinity,
                      decoration: const BoxDecoration(
                        color: AppColors.cardBackground,
                        borderRadius: BorderRadius.all(Radius.circular(32)),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.shadowMedium,
                            blurRadius: 24,
                            offset: Offset(0, -4),
                          ),
                        ],
                      ),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(28, 32, 28, 24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Text(
                              'Transporte escolar\nseguro e organizado',
                              textAlign: TextAlign.center,
                              style: AppTextStyles.heading2,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'Conecte-se com frotas, acompanhe viagens\ne tenha tranquilidade',
                              textAlign: TextAlign.center,
                              style: AppTextStyles.subtitle,
                            ),
                            const SizedBox(height: 32),
                            VanGoButton(
                              text: 'Entrar',
                              onPressed: () {
                                Navigator.pushNamed(context, AppRoutes.login);
                              },
                            ),
                            const SizedBox(height: 14),
                            VanGoButton(
                              text: 'Criar Conta',
                              isOutlined: true,
                              onPressed: () {
                                Navigator.pushNamed(
                                  context,
                                  AppRoutes.register,
                                );
                              },
                            ),
                          ],
                        ),
                      ),
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
