import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../shared/widgets/vango_button.dart';
import '../services/auth_error_mapper.dart';
import '../services/auth_service.dart';

class AuthenticatedHomeScreen extends StatefulWidget {
  const AuthenticatedHomeScreen({super.key, required this.authService});

  final AuthService authService;

  @override
  State<AuthenticatedHomeScreen> createState() =>
      _AuthenticatedHomeScreenState();
}

class _AuthenticatedHomeScreenState extends State<AuthenticatedHomeScreen> {
  bool _isSigningOut = false;

  Future<void> _handleSignOut() async {
    if (_isSigningOut) return;

    setState(() => _isSigningOut = true);

    try {
      await widget.authService.signOut();
    } catch (error) {
      if (!mounted) return;

      setState(() => _isSigningOut = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AuthErrorMapper.message(error)),
          backgroundColor: AppColors.errorRed,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = widget.authService.currentSession?.user;
    final accountLabel = user?.email ?? user?.id ?? 'Conta autenticada';

    return Scaffold(
      backgroundColor: AppColors.backgroundWhite,
      appBar: AppBar(title: const Text('VanGo')),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('VanGo autenticado', style: AppTextStyles.heading2),
                const SizedBox(height: 12),
                Text(accountLabel, style: AppTextStyles.bodyMedium),
                const SizedBox(height: 32),
                VanGoButton(
                  text: 'Sair',
                  isLoading: _isSigningOut,
                  onPressed: _handleSignOut,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
