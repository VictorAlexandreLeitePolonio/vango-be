import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_auth_service.dart';
import 'package:vango_app/features/auth/screens/reset_password_screen.dart';

void main() {
  testWidgets('reset screen validates and updates the password', (
    tester,
  ) async {
    final service = FakeAuthService.signedIn(userId: 'user-1');
    addTearDown(service.dispose);

    await tester.pumpWidget(
      buildTestApp(ResetPasswordScreen(authService: service)),
    );
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'secret123');
    await tester.enterText(fields.at(1), 'secret123');
    await tester.tap(find.text('Atualizar senha'));
    await tester.pumpAndSettle();

    expect(service.updatePasswordCalls, 1);
    expect(find.text('VanGo autenticado'), findsOneWidget);
  });
}
