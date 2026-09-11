import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:vango_app/features/driver/models/driver_trip.dart';
import 'package:vango_app/features/driver/models/route_stop.dart';
import 'package:vango_app/features/driver/services/driver_route_service.dart';
import 'package:vango_app/features/driver/services/mapbox_directions_service.dart';

class FakeDirectionsService extends MapboxDirectionsService {
  int calls = 0;

  @override
  Future<DirectionsResult> getDrivingRoute({
    required String cacheKey,
    required List<LatLng> coordinates,
  }) async {
    calls++;
    return DirectionsResult(
      polylinePoints: coordinates,
      totalDistanceMeters: 8500,
      totalDurationSeconds: 1500,
      isFromCache: false,
    );
  }
}

void main() {
  test('returns initial trip with 3 default stops', () async {
    final fakeDirections = FakeDirectionsService();
    final service = DriverRouteService(directionsService: fakeDirections);

    final trip = await service.getTodayTrip();

    expect(trip.stops.length, 3);
    expect(trip.totalStudents, 2);
    expect(trip.status, TripStatus.scheduled);
    expect(trip.stops.first.name, 'Lucas Alencar');
    expect(trip.stops[1].name, 'Mariana Rios');
    expect(trip.stops[2].name, 'Colégio Objetivo / Campus Central');
  });

  test('calculates route and populates distance and duration', () async {
    final fakeDirections = FakeDirectionsService();
    final service = DriverRouteService(directionsService: fakeDirections);

    final trip = await service.calculateAndOptimizeRoute();

    expect(fakeDirections.calls, 1);
    expect(trip.totalDistanceMeters, 8500);
    expect(trip.totalDurationSeconds, 1500);
    expect(trip.formattedDistance, '8.5 km');
    expect(trip.formattedDuration, '25 min');
  });

  test('transitions through full trip lifecycle: start -> board -> finish', () async {
    final fakeDirections = FakeDirectionsService();
    final service = DriverRouteService(directionsService: fakeDirections);

    // 1. Start trip
    var trip = await service.startTrip();
    expect(trip.status, TripStatus.inProgress);
    expect(trip.nextPendingStop?.id, 'stop-01-lucas');

    // 2. Board student 1
    trip = await service.updateStopStatus('stop-01-lucas', StopStatus.boarded);
    expect(trip.completedStudentsCount, 1);
    expect(trip.nextPendingStop?.id, 'stop-02-mariana');

    // 3. Mark student 2 as boarded
    trip = await service.updateStopStatus('stop-02-mariana', StopStatus.boarded);
    expect(trip.completedStudentsCount, 2);
    expect(trip.nextPendingStop?.id, 'stop-03-colegio');

    // 4. Finish trip at school
    trip = await service.finishTrip();
    expect(trip.status, TripStatus.completed);
    expect(trip.isAllStopsCompleted, true);
  });
}
