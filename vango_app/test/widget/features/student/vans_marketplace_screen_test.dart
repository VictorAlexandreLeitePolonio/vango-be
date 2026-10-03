import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vango_app/features/student/screens/vans_marketplace_screen.dart';
import 'package:vango_app/features/student/services/student_service.dart';

import '../../../support/fake_student_data_source.dart';

void main() {
  final vanRow = {
    'id': 'van-1',
    'plate': 'ABC1D23',
    'model': 'Sprinter',
    'public_name': 'Van Norte',
    'capacity': 15,
    'fleet_id': 'fleet-1',
    'fleets': {
      'name': 'Frota Real',
      'fleet_service_schools': [
        {
          'schools': {'id': 'school-1', 'name': 'Escola Um'},
        },
      ],
    },
  };

  final studentRow = {
    'student_id': 's-1',
    'students': {'id': 's-1', 'full_name': 'Ana Souza'},
  };

  Future<void> pumpScreen(
    WidgetTester tester,
    FakeStudentDataSource source,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: VansMarketplaceScreen(
          studentService: StudentService(dataSource: source),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('renders vans returned by the backend', (tester) async {
    await pumpScreen(tester, FakeStudentDataSource(vanRows: [vanRow]));

    expect(find.text('Vans Disponíveis'), findsOneWidget);
    expect(find.textContaining('Frota Real'), findsOneWidget);
    expect(find.textContaining('ABC1D23'), findsOneWidget);
    expect(find.textContaining('Escola Um'), findsOneWidget);
    expect(find.text('Desejo entrar nesta van'), findsOneWidget);
  });

  testWidgets('shows the empty state without demo vans', (tester) async {
    await pumpScreen(tester, FakeStudentDataSource());

    expect(find.text('Nenhuma van disponível no momento.'), findsOneWidget);
    expect(find.textContaining('BRA-2E19'), findsNothing);
    expect(find.textContaining('Demo Fleet'), findsNothing);
  });

  testWidgets('shows a pt-BR error state with retry when loading fails', (
    tester,
  ) async {
    final source = FakeStudentDataSource(
      vanRows: [vanRow],
      error: apiError('forbidden'),
    );
    await pumpScreen(tester, source);

    expect(
      find.text('Você não tem permissão para realizar esta ação.'),
      findsOneWidget,
    );
    expect(find.text('Desejo entrar nesta van'), findsNothing);

    source.error = null;
    await tester.tap(find.text('Tentar novamente'));
    await tester.pumpAndSettle();

    expect(find.text('Desejo entrar nesta van'), findsOneWidget);
  });

  testWidgets('submits a join request for a real student', (tester) async {
    final source = FakeStudentDataSource(
      vanRows: [vanRow],
      studentRows: [studentRow],
    );
    await pumpScreen(tester, source);

    await tester.tap(find.text('Desejo entrar nesta van'));
    await tester.pumpAndSettle();

    expect(find.text('Solicitar Vaga'), findsOneWidget);
    expect(find.text('Ana Souza'), findsOneWidget);

    await tester.tap(find.text('Confirmar Pedido'));
    await tester.pumpAndSettle();

    expect(source.lastJoinParams!['p_student_id'], 's-1');
    expect(
      find.text('Solicitação enviada com sucesso ao dono da frota!'),
      findsOneWidget,
    );
  });

  testWidgets('shows a mapped pt-BR message when the join request fails', (
    tester,
  ) async {
    final source = FakeStudentDataSource(
      vanRows: [vanRow],
      studentRows: [studentRow],
    );
    await pumpScreen(tester, source);

    await tester.tap(find.text('Desejo entrar nesta van'));
    await tester.pumpAndSettle();

    source.error = apiError('request_conflict');
    await tester.tap(find.text('Confirmar Pedido'));
    await tester.pumpAndSettle();

    expect(
      find.text('Já existe uma solicitação pendente para este aluno.'),
      findsOneWidget,
    );
    expect(
      find.text('Solicitação enviada com sucesso ao dono da frota!'),
      findsNothing,
    );
  });
}
