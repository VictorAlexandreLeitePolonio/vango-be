import 'package:flutter/material.dart';
import 'package:vango_app/core/routes/app_routes.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vango_app/features/auth/models/access_context.dart';
import 'package:vango_app/features/fleet/screens/fleet_planning_screen.dart';
import '../../../support/fake_auth_service.dart';
import '../../../unit/features/fleet/fleet_planning_controller_test.dart';

void main() {
  test('planning route is registered', () {
    expect(AppRoutes.routes().containsKey('/fleet-planning'), isTrue);
  });
  testWidgets(
    'owner loads persisted sections and opens an independent van editor',
    (tester) async {
      final auth = FakeAuthService.signedIn(
        userId: 'user',
        accessContext: const AccessContext(
          onboardingIntent: null,
          accountRoles: {AccountRole.owner},
          dependentStudentIds: [],
          adultStudentId: null,
          fleetAccess: [
            FleetAccess(fleetId: 'fleet', roles: {AccountRole.owner}),
          ],
        ),
      );
      addTearDown(auth.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: FleetPlanningScreen(
            fleetId: 'fleet',
            userId: 'user',
            authService: auth,
            service: ControlledPlanningService(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Planejamento da frota'), findsOneWidget);
      await tester.ensureVisible(find.text('Adicionar van'));
      await tester.tap(find.text('Adicionar van'));
      await tester.pumpAndSettle();
      expect(find.text('Nova van'), findsOneWidget);
      expect(find.text('Placa'), findsOneWidget);
    },
  );
  testWidgets('changing fleet recreates the owning controller', (tester) async {
    final auth = FakeAuthService.signedIn(
      userId: 'user',
      accessContext: const AccessContext(
        onboardingIntent: null,
        accountRoles: {AccountRole.owner},
        dependentStudentIds: [],
        adultStudentId: null,
        fleetAccess: [
          FleetAccess(fleetId: 'fleet', roles: {AccountRole.owner}),
          FleetAccess(fleetId: 'other', roles: {AccountRole.owner}),
        ],
      ),
    );
    addTearDown(auth.dispose);
    final service = ControlledPlanningService();
    Widget screen(String fleet) => MaterialApp(
      home: FleetPlanningScreen(
        key: const ValueKey('planning'),
        fleetId: fleet,
        userId: 'user',
        authService: auth,
        service: service,
      ),
    );
    await tester.pumpWidget(screen('fleet'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(screen('other'));
    await tester.pumpAndSettle();
    expect(service.loadedFleets, ['fleet', 'other']);
  });
}
