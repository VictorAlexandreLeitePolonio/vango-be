import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:vango_app/features/driver/screens/driver_route_screen.dart';
import 'package:vango_app/features/driver/services/driver_route_service.dart';
import 'package:vango_app/features/driver/services/mapbox_directions_service.dart';

import '../../../unit/features/driver/driver_trip_test.dart'
    show tripProjection;
import '../../../unit/features/fleet/fleet_planning_service_test.dart'
    show planningClient, testId;

class StubDirectionsService extends MapboxDirectionsService {
  @override
  Future<DirectionsResult> getDrivingRoute({
    required String cacheKey,
    required List<LatLng> coordinates,
  }) async {
    return DirectionsResult(
      polylinePoints: coordinates,
      totalDistanceMeters: 7400,
      totalDurationSeconds: 1320,
      isFromCache: false,
    );
  }
}

/// Pumps the route screen against a fake `get_trip` backend.
Future<List<String>> pumpRouteScreen(
  WidgetTester tester, {
  Map<String, dynamic>? projection,
  int status = 200,
}) async {
  tester.view.physicalSize = const Size(1080, 1920);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final requestedTripIds = <String>[];
  final client = await tester.runAsync(
    () => planningClient((request) async {
      requestedTripIds.add(
        (jsonDecode(request.body) as Map<String, dynamic>)['p_trip_id']
            as String,
      );
      final body = status == 200
          ? projection ?? tripProjection(driverUserId: testId)
          : {'code': 'not_found', 'message': 'Trip not found'};
      return http.Response(
        jsonEncode(body),
        status,
        headers: {'content-type': 'application/json'},
        request: request,
      );
    }),
  );
  addTearDown(client!.dispose);

  await tester.pumpWidget(
    MaterialApp(
      home: DriverRouteScreen(
        tripId: 'trip-1',
        routeService: DriverRouteService(
          client: client,
          directionsService: StubDirectionsService(),
        ),
      ),
    ),
  );
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pumpAndSettle();
  return requestedTripIds;
}

void main() {
  testWidgets('loads the persisted trip by id and lets its driver start it', (
    tester,
  ) async {
    final requested = await pumpRouteScreen(tester);

    expect(requested, ['trip-1']);
    expect(find.text('Rota Manhã'), findsOneWidget);
    expect(find.text('7.4 km'), findsOneWidget);
    expect(find.text('22 min'), findsOneWidget);
    expect(find.text('Ana Souza'), findsOneWidget);
    expect(find.text('Colégio Central'), findsOneWidget);

    await tester.tap(find.text('Começar Percurso'));
    await tester.pumpAndSettle();

    expect(find.text('Próxima Parada'), findsOneWidget);
    expect(find.text('Confirmar Embarque'), findsOneWidget);
  });

  testWidgets('trips of another driver are read-only', (tester) async {
    await pumpRouteScreen(
      tester,
      projection: tripProjection(driverUserId: 'someone-else'),
    );

    expect(find.text('Começar Percurso'), findsNothing);
    expect(
      find.text('Somente o motorista designado pode operar esta viagem.'),
      findsOneWidget,
    );
  });

  testWidgets('reopening an active trip restores the active panel', (
    tester,
  ) async {
    await pumpRouteScreen(
      tester,
      projection: tripProjection(driverUserId: testId, status: 'active'),
    );

    expect(find.text('Começar Percurso'), findsNothing);
    expect(find.text('Próxima Parada'), findsOneWidget);
  });

  testWidgets('cancelled trips show their state without actions', (
    tester,
  ) async {
    await pumpRouteScreen(
      tester,
      projection: tripProjection(driverUserId: testId, status: 'cancelled'),
    );

    expect(find.text('Viagem Cancelada'), findsOneWidget);
    expect(find.text('Começar Percurso'), findsNothing);
  });

  testWidgets('backend failure renders a safe error with retry', (
    tester,
  ) async {
    await pumpRouteScreen(tester, status: 404);

    expect(find.text('Não foi possível carregar esta viagem.'), findsOneWidget);
    expect(find.textContaining('Trip not found'), findsNothing);
    expect(find.text('Tentar novamente'), findsOneWidget);
  });

  testWidgets('GPS status pill toggles between Simulation and GPS Real', (
    tester,
  ) async {
    await pumpRouteScreen(tester);

    expect(find.text('Modo: Simulação'), findsOneWidget);
    await tester.tap(find.text('Alternar'));
    await tester.pumpAndSettle();
    expect(find.text('Modo: GPS Real'), findsOneWidget);
  });
}
