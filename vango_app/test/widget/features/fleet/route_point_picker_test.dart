import 'package:flutter/material.dart';
import 'package:vango_app/features/fleet/controllers/fleet_planning_controller.dart';
import 'package:vango_app/features/fleet/widgets/route_planning_form.dart';
import '../../../unit/features/fleet/fleet_planning_controller_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vango_app/features/fleet/widgets/route_point_picker.dart';

void main() {
  testWidgets(
    'open endpoint picker clears precise draft after context invalidation',
    (tester) async {
      final controller = FleetPlanningController(
        service: RecoveryPlanningService(),
        userId: 'user',
        fleetId: 'fleet',
        refreshAccess: () async {},
      );
      addTearDown(controller.dispose);
      await controller.load();
      final route = controller.planning!.routes.first;
      await tester.pumpWidget(
        MaterialApp(
          home: RoutePlanningForm(controller: controller, initial: route),
        ),
      );
      await tester.ensureVisible(find.text('Selecionar origem'));
      await tester.tap(find.text('Selecionar origem'));
      await tester.pumpAndSettle();
      expect(find.text(route.origin.label), findsWidgets);
      controller.clearContext();
      await tester.pumpAndSettle();
      expect(find.byType(TextFormField).hitTestable(), findsNothing);
      expect(find.text(route.origin.label).hitTestable(), findsNothing);
    },
  );

  testWidgets('opening the map never confirms its default center', (
    tester,
  ) async {
    final controller = FleetPlanningController(
      service: RecoveryPlanningService(),
      userId: 'user',
      fleetId: 'fleet',
      refreshAccess: () async {},
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: RoutePointPicker(controller: controller, showTiles: false),
      ),
    );
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Confirmar ponto'),
          )
          .onPressed,
      isNull,
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Nome do ponto'),
      'Garagem',
    );
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Confirmar ponto'),
          )
          .onPressed,
      isNull,
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Latitude'),
      '-23.5',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Longitude'),
      '-46.6',
    );
    await tester.ensureVisible(find.text('Selecionar coordenadas'));
    await tester.tap(find.text('Selecionar coordenadas'));
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Confirmar ponto'),
          )
          .onPressed,
      isNotNull,
    );
  });
}
