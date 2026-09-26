import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vango_app/features/fleet/controllers/fleet_planning_controller.dart';
import 'package:vango_app/features/fleet/widgets/route_planning_form.dart';
import '../../../unit/features/fleet/fleet_planning_controller_test.dart';

void main() {
  testWidgets(
    'route requires explicit endpoints and offers independent operator selection',
    (tester) async {
      final controller = FleetPlanningController(
        service: ControlledPlanningService(),
        userId: 'user',
        fleetId: 'fleet',
        refreshAccess: () async {},
      );
      addTearDown(controller.dispose);
      await controller.load();
      await tester.pumpWidget(
        MaterialApp(home: RoutePlanningForm(controller: controller)),
      );
      expect(find.text('Motorista'), findsOneWidget);
      expect(find.text('Selecionar origem'), findsOneWidget);
      expect(find.text('Selecionar destino'), findsOneWidget);
      await tester.ensureVisible(find.text('Salvar'));
      await tester.tap(find.text('Salvar'));
      await tester.pump();
      expect(
        find.text('Selecione e confirme origem e destino.'),
        findsOneWidget,
      );
    },
  );
}
