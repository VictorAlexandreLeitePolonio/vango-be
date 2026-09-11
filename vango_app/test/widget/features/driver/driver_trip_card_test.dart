import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vango_app/features/driver/services/driver_route_service.dart';
import 'package:vango_app/features/driver/widgets/driver_trip_card.dart';

void main() {
  testWidgets('renders trip card details and triggers onViewRoute', (tester) async {
    final trip = DriverRouteService().initialTrip;
    bool viewed = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DriverTripCard(
            trip: trip,
            onViewRoute: () => viewed = true,
          ),
        ),
      ),
    );

    expect(find.text('Hoje • Manhã'), findsOneWidget);
    expect(find.text('Rota Matutina — Colégio Objetivo'), findsOneWidget);
    expect(find.text('Van BRA-2E19'), findsOneWidget);
    expect(find.text('2'), findsOneWidget); // 2 students
    expect(find.text('Alunos'), findsOneWidget);
    expect(find.text('Ver rota do dia'), findsOneWidget);

    await tester.tap(find.text('Ver rota do dia'));
    await tester.pump();

    expect(viewed, true);
  });
}
