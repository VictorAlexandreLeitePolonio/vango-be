import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_auth_service.dart';
import 'package:vango_app/features/auth/models/access_context.dart';
import 'package:vango_app/features/auth/models/onboarding_intent.dart';
import 'package:vango_app/features/auth/screens/authenticated_home_screen.dart';

void main() {
  final setupMessages = <OnboardingIntent, String>{
    OnboardingIntent.fleetOwner: 'Configure sua frota',
    OnboardingIntent.driver: 'Aguarde ou aceite um convite da frota',
    OnboardingIntent.guardian: 'Cadastre o aluno sob sua responsabilidade',
    OnboardingIntent.adultStudent: 'Complete seus dados de aluno',
  };

  for (final entry in setupMessages.entries) {
    testWidgets('${entry.key.apiValue} intent shows its setup guidance', (
      tester,
    ) async {
      final service = FakeAuthService.signedIn(userId: 'user-1');
      addTearDown(service.dispose);

      await tester.pumpWidget(
        buildTestApp(
          AuthenticatedHomeScreen(
            authService: service,
            accessContext: _context(intent: entry.key),
          ),
        ),
      );

      expect(find.text(entry.value), findsOneWidget);
      expect(find.text('Painel da frota'), findsNothing);
      expect(find.text('Minhas viagens'), findsNothing);
      expect(find.text('Meus alunos'), findsNothing);
      expect(find.text('Meu transporte'), findsNothing);
    });
  }

  final roleTitles = <AccountRole, String>{
    AccountRole.owner: 'Painel da frota',
    AccountRole.driver: 'Minhas viagens',
    AccountRole.guardian: 'Meus alunos',
    AccountRole.student: 'Meu transporte',
  };

  for (final entry in roleTitles.entries) {
    testWidgets('${entry.key.name} role shows its protected destination', (
      tester,
    ) async {
      final service = FakeAuthService.signedIn(userId: 'user-1');
      addTearDown(service.dispose);

      await tester.pumpWidget(
        buildTestApp(
          AuthenticatedHomeScreen(
            authService: service,
            accessContext: _context(
              intent: OnboardingIntent.guardian,
              roles: {entry.key},
            ),
          ),
        ),
      );

      expect(find.text(entry.value), findsOneWidget);
    });
  }

  testWidgets('switches between multiple effective roles', (tester) async {
    final service = FakeAuthService.signedIn(userId: 'user-1');
    addTearDown(service.dispose);

    await tester.pumpWidget(
      buildTestApp(
        AuthenticatedHomeScreen(
          authService: service,
          accessContext: _context(
            roles: {AccountRole.owner, AccountRole.driver},
          ),
        ),
      ),
    );

    expect(find.text('Painel da frota'), findsOneWidget);
    expect(find.byType(DropdownButton<AccountRole>), findsOneWidget);

    await tester.tap(find.byType(DropdownButton<AccountRole>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Motorista').last);
    await tester.pumpAndSettle();

    expect(find.text('Minhas viagens'), findsOneWidget);
  });

  testWidgets('shows the current account and exposes sign out', (tester) async {
    final service = FakeAuthService.signedIn(userId: 'user-1');
    addTearDown(service.dispose);

    await tester.pumpWidget(
      buildTestApp(
        AuthenticatedHomeScreen(
          authService: service,
          accessContext: _context(roles: {AccountRole.owner}),
        ),
      ),
    );

    expect(find.text('user@example.com'), findsOneWidget);
    expect(find.text('Sair'), findsOneWidget);

    await tester.tap(find.text('Sair'));
    await tester.pump();

    expect(service.signOutCalls, 1);
  });
}

AccessContext _context({
  OnboardingIntent? intent,
  Set<AccountRole> roles = const {},
}) {
  return AccessContext(
    onboardingIntent: intent,
    accountRoles: roles,
    dependentStudentIds: const [],
    adultStudentId: null,
    fleetAccess: const [],
  );
}
