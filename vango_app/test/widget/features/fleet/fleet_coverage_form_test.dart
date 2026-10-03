import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vango_app/features/fleet/controllers/fleet_planning_controller.dart';
import 'package:vango_app/features/fleet/widgets/fleet_coverage_form.dart';
import 'package:vango_app/features/fleet/widgets/fleet_school_selector.dart';
import 'package:vango_app/features/fleet/models/fleet_planning.dart';
import '../../../unit/features/fleet/fleet_planning_controller_test.dart';
import '../../../unit/features/fleet/fleet_planning_test.dart';

void main() {
  testWidgets(
    'city form requires explicit selection and commits independently',
    (tester) async {
      final service = RecoveryPlanningService();
      final controller = FleetPlanningController(
        service: service,
        userId: 'user',
        fleetId: 'fleet',
        refreshAccess: () async {},
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: FleetCoverageForm(
            controller: controller,
            kind: CoverageKind.city,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Salvar'));
      await tester.pump();
      expect(find.text('Preencha este campo.'), findsOneWidget);
      expect(service.writes, 0);
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Cidade Teste').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Salvar'));
      await tester.pumpAndSettle();
      expect(service.writes, 1);
      expect(find.text('Configuração salva.'), findsOneWidget);
    },
  );
  testWidgets(
    'school selector preserves explicit order with accessible controls',
    (tester) async {
      final first = FleetPlanning.fromJson(planningFixture()).schools.first;
      final row = Map<String, dynamic>.from(
        (planningFixture()['service_schools'] as List).first as Map,
      );
      row['school_id'] = '11111111-1111-4111-8111-111111111111';
      row['name'] = 'Second campus';
      final second = planningSchool(row, idKey: 'school_id');
      var selected = [first.id, second.id];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => SingleChildScrollView(
                child: FleetSchoolSelector(
                  options: [first, second],
                  selected: selected,
                  onChanged: (value) => setState(() => selected = value),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Mover Second campus para cima'));
      await tester.pump();
      expect(selected, [second.id, first.id]);
      await tester.tap(find.byTooltip('Remover Second campus'));
      await tester.pump();
      expect(selected, [first.id]);
      expect(tester.takeException(), isNull);
    },
  );
}
