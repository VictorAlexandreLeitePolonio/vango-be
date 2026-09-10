import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_auth_service.dart';
import 'package:vango_app/features/auth/screens/login_screen.dart';

void main() {
  testWidgets('login calls AuthService and navigates after sign-in', (
    tester,
  ) async {
    final service = FakeAuthService.signedIn(userId: 'user-1');

    await tester.pumpWidget(buildTestApp(LoginScreen(authService: service)));
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'user@example.com');
    await tester.enterText(fields.at(1), 'secret123');
    await tester.tap(find.text('Entrar'));
    await tester.pumpAndSettle();

    expect(service.signInCalls, 1);
    expect(find.text('VanGo autenticado'), findsOneWidget);
  });
}
