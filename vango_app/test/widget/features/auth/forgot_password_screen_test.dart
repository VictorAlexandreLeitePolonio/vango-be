import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_auth_service.dart';
import 'package:vango_app/features/auth/screens/forgot_password_screen.dart';

void main() {
  testWidgets('forgot password requests a reset email', (tester) async {
    final service = FakeAuthService.signedOut();
    addTearDown(service.dispose);

    await tester.pumpWidget(
      buildTestApp(ForgotPasswordScreen(authService: service)),
    );
    await tester.enterText(
      find.byType(TextFormField).first,
      'user@example.com',
    );
    await tester.tap(find.text('Enviar link'));
    await tester.pumpAndSettle();

    expect(service.passwordResetCalls, 1);
    expect(find.text('E-mail enviado!'), findsOneWidget);
  });
}
