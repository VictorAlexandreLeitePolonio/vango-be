import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../support/fake_auth_service.dart';
import 'package:vango_app/features/auth/widgets/auth_gate.dart';

void main() {
  testWidgets('shows public entry when there is no session', (tester) async {
    final service = FakeAuthService.signedOut();
    addTearDown(service.dispose);

    await tester.pumpWidget(buildTestApp(AuthGate(authService: service)));

    expect(
      find.text('Transporte escolar\nseguro e organizado'),
      findsOneWidget,
    );
  });

  testWidgets('shows the authenticated destination for an existing session', (
    tester,
  ) async {
    final service = FakeAuthService.signedIn(userId: 'user-1');
    addTearDown(service.dispose);

    await tester.pumpWidget(buildTestApp(AuthGate(authService: service)));

    expect(find.text('VanGo autenticado'), findsOneWidget);
    expect(find.text('Sair'), findsOneWidget);
  });

  testWidgets('sign out returns to the public entry', (tester) async {
    final service = FakeAuthService.signedIn(userId: 'user-1');
    addTearDown(service.dispose);

    await tester.pumpWidget(buildTestApp(AuthGate(authService: service)));
    await tester.tap(find.text('Sair'));
    await tester.pump();

    expect(service.signOutCalls, 1);
    expect(
      find.text('Transporte escolar\nseguro e organizado'),
      findsOneWidget,
    );
  });

  testWidgets('shows password reset after a recovery event', (tester) async {
    final service = FakeAuthService.signedIn(userId: 'user-1');
    addTearDown(service.dispose);
    final recoverySession = service.session;

    await tester.pumpWidget(buildTestApp(AuthGate(authService: service)));
    service.emit(
      AuthChangeEvent.passwordRecovery,
      nextSession: recoverySession,
    );
    await tester.pump();

    expect(find.text('Redefinir senha'), findsOneWidget);
  });
}
