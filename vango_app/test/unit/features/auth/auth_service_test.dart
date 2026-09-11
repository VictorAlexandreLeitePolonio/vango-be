import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../support/fake_auth_client.dart';

import 'package:vango_app/features/auth/models/onboarding_intent.dart';
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
      onboardingIntent: OnboardingIntent.guardian,
    );

    expect(client.lastSignUpData, {
      'full_name': 'Maria Silva',
      'onboarding_intent': 'guardian',
    });
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
        onboardingIntent: OnboardingIntent.adultStudent,
      );

      expect(result.hasSession, isFalse);
      expect(client.updatedProfile, isNull);
    },
  );

  test('loads and parses exactly one access context row', () async {
    final client = FakeAuthClient.signedIn(
      userId: 'user-1',
      accessContextRows: [
        {
          'onboarding_intent': 'driver',
          'account_roles': ['driver'],
          'dependent_student_ids': <String>[],
          'adult_student_id': null,
          'fleet_access': [
            {
              'fleet_id': 'fleet-1',
              'roles': ['driver'],
            },
          ],
        },
      ],
    );
    final service = SupabaseAuthService(client: client);

    final context = await service.getMyAccessContext();

    expect(context.onboardingIntent, OnboardingIntent.driver);
    expect(context.fleetAccess.single.fleetId, 'fleet-1');
    expect(client.accessContextCalls, 1);
  });

  test('rejects zero or duplicated access context rows', () async {
    final emptyService = SupabaseAuthService(
      client: FakeAuthClient.signedIn(userId: 'user-1'),
    );
    final duplicatedService = SupabaseAuthService(
      client: FakeAuthClient.signedIn(
        userId: 'user-1',
        accessContextRows: [<String, dynamic>{}, <String, dynamic>{}],
      ),
    );

    await expectLater(emptyService.getMyAccessContext(), throwsFormatException);
    await expectLater(
      duplicatedService.getMyAccessContext(),
      throwsFormatException,
    );
  });

  test('delegates password recovery, password update, and sign-out', () async {
    final client = FakeAuthClient.signedIn(userId: 'user-1');
    final service = SupabaseAuthService(client: client);

    expect(service.currentSession, same(client.session));
    expect(service.authStateChanges, isA<Stream<AuthState>>());

    await service.sendPasswordReset(email: ' maria@example.com ');
    await service.updatePassword(password: 'new-secret');
    await service.signOut();

    expect(client.lastEmail, 'maria@example.com');
    expect(client.lastRedirectTo, 'com.vango.vangoapp://auth-callback/');
    expect(client.lastUpdatedPassword, 'new-secret');
    expect(client.resetPasswordCalls, 1);
    expect(client.updatePasswordCalls, 1);
    expect(client.signOutCalls, 1);
  });
}
