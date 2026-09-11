import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:vango_app/features/auth/models/access_context.dart';
import 'package:vango_app/features/auth/models/auth_result.dart';
import 'package:vango_app/features/auth/models/onboarding_intent.dart';
import 'package:vango_app/features/auth/services/auth_service.dart';

class FakeAuthService implements AuthService {
  FakeAuthService._({
    required this.userId,
    required this.session,
    required this.accessContext,
  });

  factory FakeAuthService.signedIn({
    required String userId,
    AccessContext? accessContext,
  }) {
    final user = _createUser(userId);
    return FakeAuthService._(
      userId: userId,
      session: Session(
        accessToken: 'access-token',
        refreshToken: 'refresh-token',
        tokenType: 'bearer',
        user: user,
      ),
      accessContext: accessContext ?? _emptyAccessContext,
    );
  }

  factory FakeAuthService.signedOut() {
    return FakeAuthService._(
      userId: null,
      session: null,
      accessContext: _emptyAccessContext,
    );
  }

  factory FakeAuthService.emailConfirmationRequired() {
    return FakeAuthService._(
      userId: 'user-1',
      session: null,
      accessContext: _emptyAccessContext,
    );
  }

  final StreamController<AuthState> _authStateController =
      StreamController<AuthState>.broadcast();

  String? userId;
  Session? session;
  int signInCalls = 0;
  int signUpCalls = 0;
  int passwordResetCalls = 0;
  int updatePasswordCalls = 0;
  int signOutCalls = 0;
  String? lastEmail;
  String? lastFullName;
  String? lastPassword;
  OnboardingIntent? lastOnboardingIntent;
  AccessContext accessContext;
  Completer<AccessContext>? accessCompleter;
  Object? nextAccessError;
  int accessContextCalls = 0;

  @override
  Session? get currentSession => session;

  @override
  Stream<AuthState> get authStateChanges => _authStateController.stream;

  @override
  Future<AuthResult> signIn({
    required String email,
    required String password,
  }) async {
    signInCalls += 1;
    lastEmail = email;
    lastPassword = password;
    return AuthResult(userId: userId, hasSession: session != null);
  }

  @override
  Future<AuthResult> signUp({
    required String fullName,
    required String email,
    required String password,
    required OnboardingIntent onboardingIntent,
  }) async {
    signUpCalls += 1;
    lastFullName = fullName;
    lastEmail = email;
    lastPassword = password;
    lastOnboardingIntent = onboardingIntent;
    return AuthResult(userId: userId, hasSession: session != null);
  }

  @override
  Future<AccessContext> getMyAccessContext() async {
    accessContextCalls += 1;
    final error = nextAccessError;
    nextAccessError = null;
    if (error != null) throw error;
    return accessCompleter?.future ?? accessContext;
  }

  @override
  Future<void> sendPasswordReset({required String email}) async {
    passwordResetCalls += 1;
    lastEmail = email;
  }

  @override
  Future<void> updatePassword({required String password}) async {
    updatePasswordCalls += 1;
    lastPassword = password;
  }

  @override
  Future<void> signOut() async {
    signOutCalls += 1;
    session = null;
    _authStateController.add(const AuthState(AuthChangeEvent.signedOut, null));
  }

  void emit(AuthChangeEvent event, {Session? nextSession}) {
    session = nextSession;
    _authStateController.add(AuthState(event, session));
  }

  Future<void> dispose() => _authStateController.close();

  static User _createUser(String userId) {
    return User(
      id: userId,
      appMetadata: const {},
      userMetadata: const {},
      aud: 'authenticated',
      email: 'user@example.com',
      createdAt: '2026-01-01T00:00:00.000Z',
    );
  }

  static const _emptyAccessContext = AccessContext(
    onboardingIntent: null,
    accountRoles: {},
    dependentStudentIds: [],
    adultStudentId: null,
    fleetAccess: [],
  );
}

Widget buildTestApp(Widget child) {
  return MaterialApp(
    home: child,
    routes: {
      '/authenticated': (_) =>
          const Scaffold(body: Center(child: Text('VanGo autenticado'))),
    },
  );
}
