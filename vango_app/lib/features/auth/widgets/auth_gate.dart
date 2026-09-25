import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/access_context.dart';
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
  bool _isLoadingAccess = false;
  Object? _accessError;
  AccessContext? _accessContext;
  int _accessRequestId = 0;
  StreamSubscription<AuthState>? _authStateSubscription;

  @override
  void initState() {
    super.initState();
    _session = widget.authService.currentSession;
    if (_session != null) {
      _isLoadingAccess = true;
      unawaited(_loadAccess(_session!, updateLoadingState: false));
    }
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
        final session = state.session;
        if (session == null) {
          _clearSession();
          return;
        }
        if (_session?.user.id == session.user.id &&
            (_isLoadingAccess || _accessContext != null)) {
          setState(() => _session = session);
          return;
        }
        setState(() {
          _session = session;
          _isRecovering = false;
        });
        unawaited(_loadAccess(session));
      case AuthChangeEvent.signedIn:
      case AuthChangeEvent.userUpdated:
        final session = state.session;
        if (session == null) {
          _clearSession();
          return;
        }
        setState(() {
          _session = session;
          _isRecovering = false;
        });
        unawaited(_loadAccess(session));
      case AuthChangeEvent.passwordRecovery:
        _accessRequestId += 1;
        setState(() {
          _session = state.session;
          _isRecovering = true;
        });
      case AuthChangeEvent.tokenRefreshed:
        setState(() {
          _session = state.session;
        });
      case AuthChangeEvent.signedOut:
        _clearSession();
      default:
        break;
    }
  }

  void _clearSession() {
    _accessRequestId += 1;
    setState(() {
      _session = null;
      _isRecovering = false;
      _isLoadingAccess = false;
      _accessError = null;
      _accessContext = null;
    });
  }

  Future<void> _loadAccess(
    Session session, {
    bool updateLoadingState = true,
  }) async {
    final requestId = ++_accessRequestId;
    final userId = session.user.id;

    if (updateLoadingState && mounted) {
      setState(() {
        _isLoadingAccess = true;
        _accessError = null;
        _accessContext = null;
      });
    }

    try {
      final accessContext = await widget.authService.getMyAccessContext();
      if (!mounted ||
          requestId != _accessRequestId ||
          _session?.user.id != userId) {
        return;
      }
      setState(() {
        _accessContext = accessContext;
        _isLoadingAccess = false;
        _accessError = null;
      });
    } catch (error) {
      if (!mounted ||
          requestId != _accessRequestId ||
          _session?.user.id != userId) {
        return;
      }
      setState(() {
        _isLoadingAccess = false;
        _accessError = error;
      });
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

    if (_isLoadingAccess) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (_accessError != null) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Não foi possível carregar seu acesso'),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () {
                  final session = _session;
                  if (session != null) unawaited(_loadAccess(session));
                },
                child: const Text('Tentar novamente'),
              ),
            ],
          ),
        ),
      );
    }

    final accessContext = _accessContext;
    if (accessContext == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return AuthenticatedHomeScreen(
      key: ValueKey(_session!.user.id),
      authService: widget.authService,
      accessContext: accessContext,
    );
  }
}
