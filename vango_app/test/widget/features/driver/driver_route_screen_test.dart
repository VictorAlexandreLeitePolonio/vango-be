import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:vango_app/features/driver/screens/driver_route_screen.dart';
import 'package:vango_app/features/driver/services/driver_route_service.dart';
import 'package:vango_app/features/driver/services/mapbox_directions_service.dart';

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

void main() {
  testWidgets('renders route screen, stops and triggers trip start', (tester) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final routeService = DriverRouteService(
      directionsService: StubDirectionsService(),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: DriverRouteScreen(routeService: routeService),
      ),
    );

    // Let the route calculation complete
    await tester.pumpAndSettle();

    expect(find.text('Rota do Dia'), findsOneWidget);
    expect(find.text('7.4 km'), findsOneWidget);
    expect(find.text('22 min'), findsOneWidget);
    expect(find.text('Melhor trajeto'), findsOneWidget);

    // Check stops
    expect(find.text('Lucas Alencar'), findsOneWidget);
    expect(find.text('Mariana Rios'), findsOneWidget);
    expect(find.text('Colégio Objetivo / Campus Central'), findsOneWidget);
    expect(find.text('Começar Percurso'), findsOneWidget);

    // Tap start trip
    await tester.tap(find.text('Começar Percurso'));
    await tester.pumpAndSettle();

    // Now active trip panel appears with next stop
    expect(find.text('Próxima Parada'), findsOneWidget);
    expect(find.text('Confirmar Embarque'), findsOneWidget);
    expect(find.text('Ausente'), findsOneWidget);
  });
}
