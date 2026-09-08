import 'package:flutter/material.dart';

import '../../../core/routes/app_routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../shared/widgets/vango_button.dart';
import '../../../shared/widgets/vango_logo.dart';
import '../../../shared/widgets/vango_text_field.dart';

/// Register screen (new account registration).
///
/// Fields: full name, email, password, and password confirmation.
/// Local validation with simulated loading.
class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

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
  bool _isLoading = false;

  late AnimationController _animController;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
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

    setState(() => _isLoading = true);

    // Simulated loading — will be replaced by Supabase Auth integration
    await Future.delayed(const Duration(milliseconds: 1500));

    if (!mounted) return;

    setState(() => _isLoading = false);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Account created successfully! Please check your email.',
          style: AppTextStyles.bodySmall.copyWith(color: AppColors.textLight),
        ),
        backgroundColor: AppColors.successGreen,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  String? _validateName(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Please enter your full name';
    }
    if (value.trim().length < 3) {
      return 'Name must be at least 3 characters';
    }
    return null;
  }

  String? _validateEmail(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Please enter your email';
    }
    final emailRegex = RegExp(r'^[\w\.\-]+@[\w\-]+\.\w{2,}$');
    if (!emailRegex.hasMatch(value.trim())) {
      return 'Invalid email address';
    }
    return null;
  }

  String? _validatePassword(String? value) {
    if (value == null || value.isEmpty) {
      return 'Please create a password';
    }
    if (value.length < 6) {
      return 'Password must be at least 6 characters';
    }
    return null;
  }

  String? _validateConfirmPassword(String? value) {
    if (value == null || value.isEmpty) {
      return 'Please confirm your password';
    }
    if (value != _passwordController.text) {
      return 'Passwords do not match';
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
                  Text('Create your account', style: AppTextStyles.heading2),
                  const SizedBox(height: 8),
                  Text(
                    'Get started with VanGo today',
                    style: AppTextStyles.subtitle,
                  ),
                  const SizedBox(height: 32),

                  // ── Name field ────────────────────────────
                  VanGoTextField(
                    controller: _nameController,
                    label: 'Full name',
                    hint: 'Your name',
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
                    label: 'Email',
                    hint: 'you@email.com',
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
                    label: 'Password',
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
                    label: 'Confirm password',
                    hint: '••••••',
                    prefixIcon: Icons.lock_outline_rounded,
                    isPassword: true,
                    textInputAction: TextInputAction.done,
                    validator: _validateConfirmPassword,
                    onFieldSubmitted: (_) => _handleRegister(),
                  ),
                  const SizedBox(height: 32),

                  // ── Submit button ─────────────────────────
                  VanGoButton(
                    text: 'Create Account',
                    isLoading: _isLoading,
                    onPressed: _handleRegister,
                  ),
                  const SizedBox(height: 24),

                  // ── Login link ────────────────────────────
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'Already have an account? ',
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
                        child: Text('Sign In', style: AppTextStyles.link),
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
    );
  }
}
