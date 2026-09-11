import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../shared/widgets/vango_button.dart';
import '../../../shared/widgets/vango_logo.dart';
import '../../../shared/widgets/vango_text_field.dart';
import '../services/auth_error_mapper.dart';
import '../services/auth_service.dart';

/// Password recovery screen.
///
/// Email field with local validation and Supabase recovery email request.
class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key, this.authService});

  final AuthService? authService;

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen>
    with SingleTickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  bool _isLoading = false;
  bool _emailSent = false;
  late final AuthService _authService;

  late AnimationController _animController;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _authService = widget.authService ?? SupabaseAuthService();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _animController,
      curve: Curves.easeOut,
    );
    _animController.forward();
  }

  @override
  void dispose() {
    _emailController.dispose();
    _animController.dispose();
    super.dispose();
  }

  Future<void> _handleSendLink() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      await _authService.sendPasswordReset(email: _emailController.text);

      if (!mounted) return;

      setState(() {
        _isLoading = false;
        _emailSent = true;
      });

      _showMessage(
        'Link de recuperação enviado para ${_emailController.text.trim()}',
      );
    } catch (error) {
      if (!mounted) return;

      setState(() => _isLoading = false);
      _showMessage(AuthErrorMapper.message(error), isError: true);
    }
  }

  void _showMessage(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: AppTextStyles.bodySmall.copyWith(color: AppColors.textLight),
        ),
        backgroundColor: isError ? AppColors.errorRed : AppColors.successGreen,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        margin: const EdgeInsets.all(16),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  String? _validateEmail(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Informe seu e-mail';
    }
    final emailRegex = RegExp(r'^[\w\.\-]+@[\w\-]+\.\w{2,}$');
    if (!emailRegex.hasMatch(value.trim())) {
      return 'E-mail inválido';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundWhite,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SafeArea(
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      const SizedBox(height: 24),

                      // ── Logo ──────────────────────────────────
                      const VanGoLogo(size: VanGoLogoSize.medium),
                      const SizedBox(height: 40),

                      // ── Icon ──────────────────────────────────
                      Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          gradient: AppColors.primaryGradient,
                          borderRadius: BorderRadius.circular(24),
                          boxShadow: [
                            BoxShadow(
                              color: AppColors.primaryOrange.withValues(
                                alpha: 0.2,
                              ),
                              blurRadius: 16,
                              offset: const Offset(0, 6),
                            ),
                          ],
                        ),
                        child: Icon(
                          _emailSent
                              ? Icons.mark_email_read_outlined
                              : Icons.lock_reset_rounded,
                          color: AppColors.textDark,
                          size: 34,
                        ),
                      ),
                      const SizedBox(height: 28),

                      // ── Title ─────────────────────────────────
                      Text(
                        _emailSent ? 'E-mail enviado!' : 'Recuperar senha',
                        style: AppTextStyles.heading2,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        _emailSent
                            ? 'Verifique sua caixa de entrada e siga as instruções para redefinir sua senha.'
                            : 'Informe seu e-mail para receber o link de recuperação',
                        textAlign: TextAlign.center,
                        style: AppTextStyles.subtitle,
                      ),
                      const SizedBox(height: 36),

                      if (!_emailSent) ...[
                        // ── Email field ─────────────────────────
                        VanGoTextField(
                          controller: _emailController,
                          label: 'E-mail',
                          hint: 'seu@email.com',
                          prefixIcon: Icons.email_outlined,
                          keyboardType: TextInputType.emailAddress,
                          textInputAction: TextInputAction.done,
                          autofillHints: const [AutofillHints.email],
                          validator: _validateEmail,
                          onFieldSubmitted: (_) => _handleSendLink(),
                        ),
                        const SizedBox(height: 32),

                        // ── Submit button ───────────────────────
                        VanGoButton(
                          text: 'Enviar link',
                          isLoading: _isLoading,
                          onPressed: _handleSendLink,
                        ),
                      ] else ...[
                        // ── Back to Login button ────────────────
                        VanGoButton(
                          text: 'Voltar ao Login',
                          onPressed: () => Navigator.pop(context),
                        ),
                        const SizedBox(height: 16),
                        TextButton(
                          onPressed: () {
                            setState(() => _emailSent = false);
                            _emailController.clear();
                          },
                          child: Text(
                            'Enviar novamente',
                            style: AppTextStyles.link,
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
