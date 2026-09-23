import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:vango_app/features/driver/models/route_stop.dart';
import 'package:vango_app/features/driver/services/driver_location_service.dart';

void main() {
  test('calculateBearing calculates accurate azimuth heading between points', () {
    const p1 = LatLng(0.0, 0.0);
    const pNorth = LatLng(1.0, 0.0);
    const pEast = LatLng(0.0, 1.0);
    const pSouth = LatLng(-1.0, 0.0);
    const pWest = LatLng(0.0, -1.0);

    final bearingNorth = DriverLocationService.calculateBearing(p1, pNorth);
    final bearingEast = DriverLocationService.calculateBearing(p1, pEast);
    final bearingSouth = DriverLocationService.calculateBearing(p1, pSouth);
    final bearingWest = DriverLocationService.calculateBearing(p1, pWest);

    expect(bearingNorth, closeTo(0.0, 0.1));
    expect(bearingEast, closeTo(90.0, 0.1));
    expect(bearingSouth, closeTo(180.0, 0.1));
    expect(bearingWest, closeTo(270.0, 0.1));
  });

  test('calculateDistanceMeters calculates accurate distance in meters', () {
    const p1 = LatLng(-23.5615, -46.6698); // Oscar Freire
    const p2 = LatLng(-23.5601, -46.6575); // Alameda Santos

    final distance = DriverLocationService.calculateDistanceMeters(p1, p2);
    // Around 1250 - 1300 meters apart in direct line
    expect(distance, inInclusiveRange(1200.0, 1400.0));
  });

  test('simulation mode emits telemetry updates and detects proximity to stop', () async {
    final service = DriverLocationService();

    const stop1 = RouteStop(
      id: 'stop-01',
      name: 'Lucas Alencar',
      address: 'Rua Oscar Freire, 1000',
      scheduledTime: '06:45',
      latitude: -23.5615,
      longitude: -46.6698,
      type: StopType.pickup,
    );

    // 3 route points: point 0 is far, point 1 is very close (< 20m) to stop1, point 2 is destination
    const routePoints = [
      LatLng(-23.5700, -46.6750), // ~1000m away
      LatLng(-23.56152, -46.66982), // ~2m from stop1
      LatLng(-23.5745, -46.6405), // destination
    ];

    final updates = <VanTelemetryUpdate>[];
    final sub = service.telemetryStream.listen(updates.add);

    await service.startTracking(
      routePoints: routePoints,
      pendingStops: [stop1],
      mode: LocationTrackingMode.simulation,
    );

    expect(service.isTracking, true);

    // Wait for simulation ticks
    await Future.delayed(const Duration(milliseconds: 2600));

    service.stopTracking();
    await sub.cancel();
    service.dispose();

    expect(updates.length, greaterThanOrEqualTo(2));
    expect(updates.first.position, routePoints.first);
    expect(updates.first.speedKmh, 35.0);

    // Check that point 1 triggered proximity (< 50m) to stop1
    final nearStopUpdate = updates.firstWhere((u) => u.isApproachingStop);
    expect(nearStopUpdate.approachingStop?.id, 'stop-01');
    expect(nearStopUpdate.distanceToNextStopMeters, lessThan(50.0));
  });
}
