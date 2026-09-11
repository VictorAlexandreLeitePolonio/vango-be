import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_auth_service.dart';
import 'package:vango_app/features/auth/screens/authenticated_home_screen.dart';

void main() {
  testWidgets('shows the current account and exposes sign out', (tester) async {
    final service = FakeAuthService.signedIn(userId: 'user-1');
    addTearDown(service.dispose);

    await tester.pumpWidget(
      buildTestApp(AuthenticatedHomeScreen(authService: service)),
    );

    expect(find.text('VanGo autenticado'), findsOneWidget);
    expect(find.text('user@example.com'), findsOneWidget);
    expect(find.text('Sair'), findsOneWidget);

    await tester.tap(find.text('Sair'));
    await tester.pump();

    expect(service.signOutCalls, 1);
  });
}
