import 'package:flutter/material.dart';

import '../../features/auth/screens/forgot_password_screen.dart';
import '../../features/auth/screens/login_screen.dart';
import '../../features/auth/screens/register_screen.dart';
import '../../features/auth/screens/reset_password_screen.dart';
import '../../features/auth/screens/welcome_screen.dart';
import '../../features/auth/services/auth_service.dart';
import '../../features/auth/widgets/auth_gate.dart';

/// Named routes for the VanGo application.
class AppRoutes {
  AppRoutes._();

  static const String welcome = '/welcome';
  static const String login = '/login';
  static const String register = '/register';
  static const String forgotPassword = '/forgot-password';
  static const String resetPassword = '/reset-password';
  static const String authenticatedHome = '/authenticated';

  static Map<String, WidgetBuilder> routes({AuthService? authService}) => {
    welcome: (_) => const WelcomeScreen(),
    login: (_) => LoginScreen(authService: authService),
    register: (_) => RegisterScreen(authService: authService),
    forgotPassword: (_) => ForgotPasswordScreen(authService: authService),
    resetPassword: (_) =>
        ResetPasswordScreen(authService: authService ?? SupabaseAuthService()),
    authenticatedHome: (_) =>
        AuthGate(authService: authService ?? SupabaseAuthService()),
  };
}
