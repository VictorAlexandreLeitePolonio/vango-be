import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../screens/authenticated_home_screen.dart';
import '../screens/reset_password_screen.dart';
import '../screens/welcome_screen.dart';
import '../services/auth_error_mapper.dart';
import '../services/auth_service.dart';

class AuthGate extends StatefulWidget {
  const AuthGate({super.key, required this.authService});

  final AuthService authService;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  Session? _session;
  bool _isRecovering = false;
  StreamSubscription<AuthState>? _authStateSubscription;

  @override
  void initState() {
    super.initState();
    _session = widget.authService.currentSession;
    _authStateSubscription = widget.authService.authStateChanges.listen(
      _handleAuthState,
      onError: _handleAuthError,
    );
  }

  @override
  void dispose() {
    _authStateSubscription?.cancel();
    super.dispose();
  }

  void _handleAuthState(AuthState state) {
    if (!mounted) return;

    switch (state.event) {
      case AuthChangeEvent.initialSession:
      case AuthChangeEvent.signedIn:
      case AuthChangeEvent.tokenRefreshed:
        setState(() {
          _session = state.session;
          _isRecovering = false;
        });
      case AuthChangeEvent.passwordRecovery:
        setState(() {
          _session = state.session;
          _isRecovering = true;
        });
      case AuthChangeEvent.userUpdated:
        setState(() {
          _session = state.session;
          _isRecovering = false;
        });
      case AuthChangeEvent.signedOut:
        setState(() {
          _session = null;
          _isRecovering = false;
        });
      default:
        break;
    }
  }

  void _handleAuthError(Object error, StackTrace _) {
    if (!mounted) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AuthErrorMapper.message(error)),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_session == null) {
      return const WelcomeScreen();
    }

    if (_isRecovering) {
      return ResetPasswordScreen(authService: widget.authService);
    }

    return AuthenticatedHomeScreen(authService: widget.authService);
  }
}
