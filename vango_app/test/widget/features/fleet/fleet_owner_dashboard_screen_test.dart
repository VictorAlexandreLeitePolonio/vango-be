import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vango_app/features/fleet/screens/fleet_owner_dashboard_screen.dart';
import 'package:vango_app/features/fleet/services/fleet_service.dart';

void main() {
  setUp(() {
    FleetService.resetLocalData();
  });

  tearDown(() {
    FleetService.resetLocalData();
  });

  testWidgets('renders fleet dashboard tabs and pending student requests', (tester) async {
    final fleetService = FleetService();

    await tester.pumpWidget(
      MaterialApp(
        home: FleetOwnerDashboardScreen(fleetService: fleetService),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Gestão da Frota'), findsOneWidget);
    expect(find.textContaining('Pedidos'), findsOneWidget);
    expect(find.text('Vans & Equipe'), findsOneWidget);
    expect(find.textContaining('Alunos'), findsOneWidget);

    // Initial pending card (Carlos)
    expect(find.text('Carlos Eduardo Oliveira'), findsOneWidget);
    expect(find.text('Destino: Colégio Objetivo - Campus Paraíso'), findsOneWidget);
    expect(find.text('Aprovar Entrada'), findsOneWidget);
    expect(find.text('Recusar'), findsOneWidget);
  });

  testWidgets('approves a pending request and shows success message', (tester) async {
    final fleetService = FleetService();

    await tester.pumpWidget(
      MaterialApp(
        home: FleetOwnerDashboardScreen(fleetService: fleetService),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Carlos Eduardo Oliveira'), findsOneWidget);

    // Tap Aprovar Entrada
    await tester.tap(find.text('Aprovar Entrada'));
    await tester.pumpAndSettle();

    // Verify empty state or request removed
    expect(find.text('Carlos Eduardo Oliveira'), findsNothing);
    expect(find.text('Aluno aprovado e adicionado à frota!'), findsOneWidget);
  });

  testWidgets('navigates to Vans & Equipe and Alunos tabs successfully', (tester) async {
    final fleetService = FleetService();

    await tester.pumpWidget(
      MaterialApp(
        home: FleetOwnerDashboardScreen(fleetService: fleetService),
      ),
    );
    await tester.pumpAndSettle();

    // Tap Vans & Equipe tab
    await tester.tap(find.text('Vans & Equipe'));
    await tester.pumpAndSettle();

    expect(find.text('Carlos Seed Driver'), findsOneWidget);
    expect(find.textContaining('BRA-2E19'), findsNWidgets(2));

    // Tap Alunos tab
    await tester.tap(find.textContaining('Alunos'));
    await tester.pumpAndSettle();

    expect(find.text('Lucas Alencar'), findsOneWidget);
    expect(find.text('Mariana Rios'), findsOneWidget);
  });
}
