import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/auth_result.dart';

abstract interface class AuthService {
  Session? get currentSession;

  Stream<AuthState> get authStateChanges;

  Future<AuthResult> signIn({required String email, required String password});

  Future<AuthResult> signUp({
    required String fullName,
    required String email,
    required String password,
  });

  Future<void> sendPasswordReset({required String email});

  Future<void> updatePassword({required String password});

  Future<void> signOut();
}

abstract interface class AuthClient {
  Session? get currentSession;

  Stream<AuthState> get authStateChanges;

  Future<AuthResponse> signInWithPassword({
    required String email,
    required String password,
  });

  Future<AuthResponse> signUp({
    required String email,
    required String password,
    Map<String, dynamic>? data,
    String? emailRedirectTo,
  });

  Future<void> resetPasswordForEmail(String email, {String? redirectTo});

  Future<UserResponse> updateUser(UserAttributes attributes);

  Future<void> signOut();

  Future<void> updateOwnProfile({
    required String userId,
    required String fullName,
  });
}

class SupabaseAuthClient implements AuthClient {
  const SupabaseAuthClient(this._client);

  final SupabaseClient _client;

  @override
  Session? get currentSession => _client.auth.currentSession;

  @override
  Stream<AuthState> get authStateChanges => _client.auth.onAuthStateChange;

  @override
  Future<AuthResponse> signInWithPassword({
    required String email,
    required String password,
  }) {
    return _client.auth.signInWithPassword(email: email, password: password);
  }

  @override
  Future<AuthResponse> signUp({
    required String email,
    required String password,
    Map<String, dynamic>? data,
    String? emailRedirectTo,
  }) {
    return _client.auth.signUp(
      email: email,
      password: password,
      data: data,
      emailRedirectTo: emailRedirectTo,
    );
  }

  @override
  Future<void> resetPasswordForEmail(String email, {String? redirectTo}) {
    return _client.auth.resetPasswordForEmail(email, redirectTo: redirectTo);
  }

  @override
  Future<UserResponse> updateUser(UserAttributes attributes) {
    return _client.auth.updateUser(attributes);
  }

  @override
  Future<void> signOut() {
    return _client.auth.signOut();
  }

  @override
  Future<void> updateOwnProfile({
    required String userId,
    required String fullName,
  }) async {
    await _client
        .from('profiles')
        .update({'full_name': fullName})
        .eq('id', userId);
  }
}

class SupabaseAuthService implements AuthService {
  SupabaseAuthService({AuthClient? client})
    : _client = client ?? SupabaseAuthClient(Supabase.instance.client);

  static const _authCallbackUrl = 'com.vango.vango_app://auth-callback/';

  final AuthClient _client;

  @override
  Session? get currentSession => _client.currentSession;

  @override
  Stream<AuthState> get authStateChanges => _client.authStateChanges;

  @override
  Future<AuthResult> signIn({
    required String email,
    required String password,
  }) async {
    final response = await _client.signInWithPassword(
      email: email.trim(),
      password: password,
    );

    return AuthResult(
      userId: response.user?.id,
      hasSession: response.session != null,
    );
  }

  @override
  Future<AuthResult> signUp({
    required String fullName,
    required String email,
    required String password,
  }) async {
    final response = await _client.signUp(
      email: email.trim(),
      password: password,
      data: {'full_name': fullName.trim()},
      emailRedirectTo: _authCallbackUrl,
    );
    final userId = response.user?.id;

    if (response.session != null && userId != null) {
      await _client.updateOwnProfile(userId: userId, fullName: fullName.trim());
    }

    return AuthResult(userId: userId, hasSession: response.session != null);
  }

  @override
  Future<void> sendPasswordReset({required String email}) {
    return _client.resetPasswordForEmail(
      email.trim(),
      redirectTo: _authCallbackUrl,
    );
  }

  @override
  Future<void> updatePassword({required String password}) {
    return _client.updateUser(UserAttributes(password: password));
  }

  @override
  Future<void> signOut() {
    return _client.signOut();
  }
}
