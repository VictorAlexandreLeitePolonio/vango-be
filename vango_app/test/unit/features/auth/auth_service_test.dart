import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../support/fake_auth_client.dart';

import 'package:vango_app/features/auth/services/auth_service.dart';

void main() {
  test('signIn trims the email and returns the authenticated user', () async {
    final client = FakeAuthClient.signedIn(userId: 'user-1');
    final service = SupabaseAuthService(client: client);

    final result = await service.signIn(
      email: ' user@example.com ',
      password: 'secret123',
    );

    expect(client.lastEmail, 'user@example.com');
    expect(result.userId, 'user-1');
    expect(result.hasSession, isTrue);
  });

  test('signUp updates the own profile when a session is returned', () async {
    final client = FakeAuthClient.signedIn(userId: 'user-1');
    final service = SupabaseAuthService(client: client);

    await service.signUp(
      fullName: ' Maria Silva ',
      email: 'maria@example.com',
      password: 'secret123',
    );

    expect(client.updatedProfile, {'id': 'user-1', 'full_name': 'Maria Silva'});
  });

  test(
    'signUp preserves the no-session result when email confirmation is required',
    () async {
      final client = FakeAuthClient.emailConfirmationRequired();
      final service = SupabaseAuthService(client: client);

      final result = await service.signUp(
        fullName: 'Maria Silva',
        email: 'maria@example.com',
        password: 'secret123',
      );

      expect(result.hasSession, isFalse);
      expect(client.updatedProfile, isNull);
    },
  );

  test('delegates password recovery, password update, and sign-out', () async {
    final client = FakeAuthClient.signedIn(userId: 'user-1');
    final service = SupabaseAuthService(client: client);

    expect(service.currentSession, same(client.session));
    expect(service.authStateChanges, isA<Stream<AuthState>>());

    await service.sendPasswordReset(email: ' maria@example.com ');
    await service.updatePassword(password: 'new-secret');
    await service.signOut();

    expect(client.lastEmail, 'maria@example.com');
    expect(client.lastRedirectTo, 'com.vango.vango_app://auth-callback/');
    expect(client.lastUpdatedPassword, 'new-secret');
    expect(client.resetPasswordCalls, 1);
    expect(client.updatePasswordCalls, 1);
    expect(client.signOutCalls, 1);
  });
}
