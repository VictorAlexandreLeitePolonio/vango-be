import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vango_app/features/fleet/controllers/fleet_planning_controller.dart';
import 'package:vango_app/features/fleet/widgets/route_schedule_form.dart';
import '../../../unit/features/fleet/fleet_planning_controller_test.dart';

void main() {
  testWidgets(
    'new schedules require explicit dates and support an overnight flag',
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
        MaterialApp(
          home: RouteScheduleForm(
            controller: controller,
            routeId: controller.planning!.routes.first.id,
          ),
        ),
      );
      expect(find.text('America/Sao_Paulo'), findsOneWidget);
      await tester.ensureVisible(find.text('Salvar'));
      await tester.tap(find.text('Salvar'));
      await tester.pump();
      expect(find.text('Escolha ao menos um dia.'), findsOneWidget);
      expect(find.text('Preencha este campo.'), findsWidgets);
      await tester.ensureVisible(find.text('Termina no dia seguinte'));
      await tester.tap(find.text('Termina no dia seguinte'));
      await tester.pump();
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isTrue,
      );
    },
  );
}
