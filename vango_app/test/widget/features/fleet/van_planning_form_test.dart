import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vango_app/features/fleet/controllers/fleet_planning_controller.dart';
import 'package:vango_app/features/fleet/widgets/van_planning_form.dart';
import '../../../unit/features/fleet/fleet_planning_controller_test.dart';

void main() {
  testWidgets('van form validates capacity and preserves a rejected draft', (
    tester,
  ) async {
    final controller = FleetPlanningController(
      service: ControlledPlanningService(),
      userId: 'user',
      fleetId: 'fleet',
      refreshAccess: () async {},
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(home: VanPlanningForm(controller: controller)),
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Placa'),
      'ABC1234',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Modelo'),
      'Micro',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Nome da van'),
      'Escolar',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Capacidade'),
      '101',
    );
    await tester.tap(find.text('Salvar'));
    await tester.pump();
    expect(find.text('Informe de 1 a 100 lugares.'), findsOneWidget);
    expect(find.text('Escolar'), findsOneWidget);
  });
  testWidgets(
    'small-screen large-text editing retains stale draft and hides it after access loss',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = RecoveryPlanningService()
        ..writeFailure = const PostgrestException(
          message: 'private',
          code: 'revision_conflict',
        );
      final controller = FleetPlanningController(
        service: service,
        userId: 'user',
        fleetId: 'fleet',
        refreshAccess: () async {},
      );
      addTearDown(controller.dispose);
      await controller.load();
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(1.5)),
            child: child!,
          ),
          home: VanPlanningForm(
            controller: controller,
            initial: controller.planning!.vans.first,
          ),
        ),
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Nome da van'),
        'Changed draft',
      );
      await tester.ensureVisible(find.text('Salvar'));
      await tester.tap(find.text('Salvar'));
      await tester.pumpAndSettle();
      expect(
        service.requests.single.expectedRevision,
        controller.planning!.vans.first.editRevision,
      );
      expect(
        find.text(
          'Esta configuração foi alterada. Recarregue e revise antes de salvar.',
        ),
        findsOneWidget,
      );
      expect(find.text('Changed draft'), findsOneWidget);
      expect(tester.takeException(), isNull);
      controller.clearContext();
      await tester.pump();
      expect(find.byType(TextFormField), findsNothing);
    },
  );
}
