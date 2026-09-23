import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vango_app/features/student/screens/vans_marketplace_screen.dart';
import 'package:vango_app/features/student/services/student_service.dart';

void main() {
  setUp(() {
    StudentService.resetLocalCache();
  });

  tearDown(() {
    StudentService.resetLocalCache();
  });

  testWidgets('renders marketplace available vans and their details', (tester) async {
    final studentService = StudentService();

    await tester.pumpWidget(
      MaterialApp(
        home: VansMarketplaceScreen(studentService: studentService),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Vans Disponíveis'), findsOneWidget);
    expect(find.textContaining('Demo Fleet'), findsOneWidget);
    expect(find.textContaining('BRA-2E19'), findsOneWidget);
    expect(find.textContaining('Colégio Objetivo - Campus Paraíso'), findsOneWidget);
    expect(find.text('Desejo entrar nesta van'), findsOneWidget);
  });

  testWidgets('opens join dialog and submits join request successfully', (tester) async {
    final studentService = StudentService();

    await tester.pumpWidget(
      MaterialApp(
        home: VansMarketplaceScreen(studentService: studentService),
      ),
    );
    await tester.pumpAndSettle();

    // Tap "Desejo entrar nesta van"
    await tester.tap(find.text('Desejo entrar nesta van'));
    await tester.pumpAndSettle();

    // Verify modal dialog appeared
    expect(find.text('Solicitar Vaga'), findsOneWidget);
    expect(find.text('Lucas Alencar'), findsOneWidget); // Default student
    expect(find.text('Confirmar Pedido'), findsOneWidget);

    // Tap "Confirmar Pedido"
    await tester.tap(find.text('Confirmar Pedido'));
    await tester.pumpAndSettle();

    // Verify success snackbar appears
    expect(find.text('Solicitação enviada com sucesso ao dono da frota!'), findsOneWidget);
  });
}
