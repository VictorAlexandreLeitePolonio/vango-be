import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_auth_service.dart';
import 'package:vango_app/features/auth/models/onboarding_intent.dart';
import 'package:vango_app/features/auth/screens/register_screen.dart';

void main() {
  testWidgets('register sends the full name and navigates after a session', (
    tester,
  ) async {
    final service = FakeAuthService.signedIn(userId: 'user-1');

    await tester.pumpWidget(buildTestApp(RegisterScreen(authService: service)));
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'Maria Silva');
    await tester.enterText(fields.at(1), 'maria@example.com');
    await tester.enterText(fields.at(2), 'secret123');
    await tester.enterText(fields.at(3), 'secret123');
    final guardianChoice = find.text('Sou responsável por um aluno');
    await tester.ensureVisible(guardianChoice);
    await tester.tap(guardianChoice);
    final submitButton = find.text('Criar Conta');
    await tester.ensureVisible(submitButton);
    await tester.tap(submitButton);
    await tester.pumpAndSettle();

    expect(service.signUpCalls, 1);
    expect(service.lastFullName, 'Maria Silva');
    expect(service.lastOnboardingIntent, OnboardingIntent.guardian);
    expect(find.text('VanGo autenticado'), findsOneWidget);
  });

  testWidgets('register requires an onboarding intent', (tester) async {
    final service = FakeAuthService.signedIn(userId: 'user-1');

    await tester.pumpWidget(buildTestApp(RegisterScreen(authService: service)));
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'Maria Silva');
    await tester.enterText(fields.at(1), 'maria@example.com');
    await tester.enterText(fields.at(2), 'secret123');
    await tester.enterText(fields.at(3), 'secret123');
    final submitButton = find.text('Criar Conta');
    await tester.ensureVisible(submitButton);
    await tester.tap(submitButton);
    await tester.pump();

    expect(find.text('Escolha como você usará o VanGo'), findsOneWidget);
    expect(service.signUpCalls, 0);
  });

  testWidgets(
    'register explains email confirmation when no session is returned',
    (tester) async {
      final service = FakeAuthService.emailConfirmationRequired();

      await tester.pumpWidget(
        buildTestApp(RegisterScreen(authService: service)),
      );
      final fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), 'Maria Silva');
      await tester.enterText(fields.at(1), 'maria@example.com');
      await tester.enterText(fields.at(2), 'secret123');
      await tester.enterText(fields.at(3), 'secret123');
      final studentChoice = find.text('Sou aluno maior de idade');
      await tester.ensureVisible(studentChoice);
      await tester.tap(studentChoice);
      final submitButton = find.text('Criar Conta');
      await tester.ensureVisible(submitButton);
      await tester.tap(submitButton);
      await tester.pumpAndSettle();

      expect(find.textContaining('Verifique seu e-mail'), findsOneWidget);
    },
  );
}
