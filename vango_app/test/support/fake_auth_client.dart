import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:vango_app/features/auth/services/auth_service.dart';

class FakeAuthClient implements AuthClient {
  FakeAuthClient._({
    required User user,
    required this.session,
    required this.accessContextRows,
  }) : _user = user;

  factory FakeAuthClient.signedIn({
    required String userId,
    List<Object?> accessContextRows = const [],
  }) {
    final user = _createUser(userId);
    return FakeAuthClient._(
      user: user,
      session: Session(
        accessToken: 'access-token',
        refreshToken: 'refresh-token',
        tokenType: 'bearer',
        user: user,
      ),
      accessContextRows: accessContextRows,
    );
  }

  factory FakeAuthClient.emailConfirmationRequired() {
    return FakeAuthClient._(
      user: _createUser('user-1'),
      session: null,
      accessContextRows: const [],
    );
  }

  final User _user;
  final List<Object?> accessContextRows;
  Session? session;
  String? lastEmail;
  String? lastPassword;
  String? lastRedirectTo;
  Map<String, dynamic>? lastSignUpData;
  Map<String, dynamic>? updatedProfile;
  String? lastUpdatedPassword;
  int resetPasswordCalls = 0;
  int updatePasswordCalls = 0;
  int signOutCalls = 0;
  int accessContextCalls = 0;

  @override
  Future<Object?> getMyAccessContext() async {
    accessContextCalls += 1;
    return accessContextRows;
  }

  @override
  Session? get currentSession => session;

  @override
  Stream<AuthState> get authStateChanges => const Stream<AuthState>.empty();

  @override
  Future<AuthResponse> signInWithPassword({
    required String email,
    required String password,
  }) async {
    lastEmail = email;
    lastPassword = password;
    return AuthResponse(session: session, user: _user);
  }

  @override
  Future<AuthResponse> signUp({
    required String email,
    required String password,
    Map<String, dynamic>? data,
    String? emailRedirectTo,
  }) async {
    lastEmail = email;
    lastPassword = password;
    lastSignUpData = data;
    lastRedirectTo = emailRedirectTo;
    return AuthResponse(session: session, user: _user);
  }

  @override
  Future<void> resetPasswordForEmail(String email, {String? redirectTo}) async {
    lastEmail = email;
    lastRedirectTo = redirectTo;
    resetPasswordCalls += 1;
  }

  @override
  Future<UserResponse> updateUser(UserAttributes attributes) async {
    lastUpdatedPassword = attributes.password;
    updatePasswordCalls += 1;
    return UserResponse.fromJson(_user.toJson());
  }

  @override
  Future<void> signOut() async {
    signOutCalls += 1;
    session = null;
  }

  @override
  Future<void> updateOwnProfile({
    required String userId,
    required String fullName,
  }) async {
    updatedProfile = {'id': userId, 'full_name': fullName};
  }

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
}
