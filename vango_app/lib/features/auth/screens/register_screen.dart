import 'package:flutter/material.dart';

import '../../../core/routes/app_routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';
import '../models/onboarding_intent.dart';
import '../services/auth_error_mapper.dart';
import '../services/auth_service.dart';
import '../../../shared/widgets/vango_button.dart';
import '../../../shared/widgets/vango_logo.dart';
import '../../../shared/widgets/vango_text_field.dart';

/// Register screen (new account registration).
///
/// Fields: full name, email, password, and password confirmation.
/// Local validation followed by Supabase Auth registration.
class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key, this.authService});

  final AuthService? authService;

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen>
    with SingleTickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  OnboardingIntent? _onboardingIntent;
  bool _isLoading = false;
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
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _animController.dispose();
    super.dispose();
  }

  Future<void> _handleRegister() async {
    if (!_formKey.currentState!.validate()) return;
    final onboardingIntent = _onboardingIntent;
    if (onboardingIntent == null) return;

    setState(() => _isLoading = true);

    try {
      final result = await _authService.signUp(
        fullName: _nameController.text,
        email: _emailController.text,
        password: _passwordController.text,
        onboardingIntent: onboardingIntent,
      );

      if (!mounted) return;

      setState(() => _isLoading = false);

      final message = result.hasSession
          ? 'Conta criada com sucesso!'
          : 'Conta criada com sucesso! Verifique seu e-mail.';

      if (result.hasSession) {
        Navigator.pushReplacementNamed(context, AppRoutes.authenticatedHome);
      } else {
        _showMessage(message);
      }
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
      ),
    );
  }

  String? _validateName(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Informe seu nome completo';
    }
    if (value.trim().length < 3) {
      return 'O nome deve ter pelo menos 3 caracteres';
    }
    return null;
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

  String? _validatePassword(String? value) {
    if (value == null || value.isEmpty) {
      return 'Crie uma senha';
    }
    if (value.length < 6) {
      return 'A senha deve ter pelo menos 6 caracteres';
    }
    return null;
  }

  String? _validateConfirmPassword(String? value) {
    if (value == null || value.isEmpty) {
      return 'Confirme sua senha';
    }
    if (value != _passwordController.text) {
      return 'As senhas não coincidem';
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
                      const SizedBox(height: 8),

                      // ── Logo ──────────────────────────────────
                      const VanGoLogo(size: VanGoLogoSize.medium),
                      const SizedBox(height: 28),

                      // ── Title ─────────────────────────────────
                      Text('Crie sua conta', style: AppTextStyles.heading2),
                      const SizedBox(height: 8),
                      Text(
                        'Comece a usar o VanGo agora',
                        style: AppTextStyles.subtitle,
                      ),
                      const SizedBox(height: 32),

                      // ── Name field ────────────────────────────
                      VanGoTextField(
                        controller: _nameController,
                        label: 'Nome completo',
                        hint: 'Seu nome',
                        prefixIcon: Icons.person_outline_rounded,
                        keyboardType: TextInputType.name,
                        textInputAction: TextInputAction.next,
                        autofillHints: const [AutofillHints.name],
                        validator: _validateName,
                      ),
                      const SizedBox(height: 16),

                      // ── Email field ───────────────────────────
                      VanGoTextField(
                        controller: _emailController,
                        label: 'E-mail',
                        hint: 'seu@email.com',
                        prefixIcon: Icons.email_outlined,
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.next,
                        autofillHints: const [AutofillHints.email],
                        validator: _validateEmail,
                      ),
                      const SizedBox(height: 16),

                      // ── Password field ────────────────────────
                      VanGoTextField(
                        controller: _passwordController,
                        label: 'Senha',
                        hint: '••••••',
                        prefixIcon: Icons.lock_outline_rounded,
                        isPassword: true,
                        textInputAction: TextInputAction.next,
                        autofillHints: const [AutofillHints.newPassword],
                        validator: _validatePassword,
                      ),
                      const SizedBox(height: 16),

                      // ── Confirm password field ────────────────
                      VanGoTextField(
                        controller: _confirmPasswordController,
                        label: 'Confirmar senha',
                        hint: '••••••',
                        prefixIcon: Icons.lock_outline_rounded,
                        isPassword: true,
                        textInputAction: TextInputAction.done,
                        validator: _validateConfirmPassword,
                        onFieldSubmitted: (_) => _handleRegister(),
                      ),
                      const SizedBox(height: 24),

                      FormField<OnboardingIntent>(
                        validator: (value) => value == null
                            ? 'Escolha como você usará o VanGo'
                            : null,
                        builder: (field) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Como você usará o VanGo?',
                                style: AppTextStyles.bodyMedium.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 8),
                              RadioGroup<OnboardingIntent>(
                                groupValue: field.value,
                                onChanged: (value) {
                                  field.didChange(value);
                                  setState(() => _onboardingIntent = value);
                                },
                                child: Column(
                                  children: OnboardingIntent.values.map((
                                    intent,
                                  ) {
                                    return RadioListTile<OnboardingIntent>(
                                      value: intent,
                                      title: Text(intent.label),
                                      activeColor: AppColors.primaryOrangeDark,
                                      contentPadding: EdgeInsets.zero,
                                      dense: true,
                                    );
                                  }).toList(),
                                ),
                              ),
                              if (field.hasError)
                                Padding(
                                  padding: const EdgeInsets.only(left: 12),
                                  child: Text(
                                    field.errorText!,
                                    style: AppTextStyles.caption.copyWith(
                                      color: AppColors.errorRed,
                                    ),
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: 24),

                      // ── Submit button ─────────────────────────
                      VanGoButton(
                        text: 'Criar Conta',
                        isLoading: _isLoading,
                        onPressed: _handleRegister,
                      ),
                      const SizedBox(height: 24),

                      // ── Login link ────────────────────────────
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            'Já tem conta? ',
                            style: AppTextStyles.bodyMedium.copyWith(
                              color: AppColors.textMuted,
                            ),
                          ),
                          GestureDetector(
                            onTap: () {
                              Navigator.pushReplacementNamed(
                                context,
                                AppRoutes.login,
                              );
                            },
                            child: Text('Entrar', style: AppTextStyles.link),
                          ),
                        ],
                      ),
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
