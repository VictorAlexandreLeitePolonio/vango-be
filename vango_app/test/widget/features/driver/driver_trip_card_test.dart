import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vango_app/features/driver/models/driver_trip.dart';
import 'package:vango_app/features/driver/widgets/driver_trip_card.dart';

import '../../../unit/features/driver/driver_trip_test.dart'
    show tripProjection;

Future<void> pumpCard(
  WidgetTester tester,
  DriverTrip trip, {
  required bool canOperate,
  VoidCallback? onOpen,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: DriverTripCard(
          trip: trip,
          canOperate: canOperate,
          onOpen: onOpen ?? () {},
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('renders persisted trip labels and opens the trip', (
    tester,
  ) async {
    var opened = false;
    final trip = DriverTrip.fromProjection(tripProjection());

    await pumpCard(tester, trip, canOperate: true, onOpen: () => opened = true);

    expect(find.text('Rota Manhã'), findsOneWidget);
    expect(find.text('Van ABC1D23'), findsOneWidget);
    expect(find.text('Agendada'), findsOneWidget);
    expect(find.text('1'), findsWidgets); // one student, one school
    expect(find.text('-- km'), findsOneWidget); // no fabricated distance

    await tester.tap(find.text('Iniciar viagem'));
    expect(opened, isTrue);
  });

  testWidgets('maps every backend status to a pt-BR label', (tester) async {
    const labels = {
      'scheduled': 'Agendada',
      'confirmation_closed': 'Confirmações encerradas',
      'active': 'Em andamento',
      'completed': 'Concluída',
      'cancelled': 'Cancelada',
    };
    for (final entry in labels.entries) {
      await pumpCard(
        tester,
        DriverTrip.fromProjection(tripProjection(status: entry.key)),
        canOperate: false,
      );
      expect(find.text(entry.value), findsOneWidget, reason: entry.key);
    }
  });

  testWidgets('assigned driver continues an active trip', (tester) async {
    await pumpCard(
      tester,
      DriverTrip.fromProjection(tripProjection(status: 'active')),
      canOperate: true,
    );

    expect(find.text('Continuar viagem'), findsOneWidget);
  });

  testWidgets('other drivers trips are read-only', (tester) async {
    await pumpCard(
      tester,
      DriverTrip.fromProjection(tripProjection()),
      canOperate: false,
    );

    expect(find.text('Iniciar viagem'), findsNothing);
    expect(find.text('Ver viagem'), findsOneWidget);
  });
}
