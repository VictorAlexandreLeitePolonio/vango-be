import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:vango_app/features/driver/models/route_stop.dart';
import 'package:vango_app/features/driver/services/driver_location_service.dart';

void main() {
  test(
    'calculateBearing calculates accurate azimuth heading between points',
    () {
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
    },
  );

  test('calculateDistanceMeters calculates accurate distance in meters', () {
    const p1 = LatLng(-23.5615, -46.6698); // Oscar Freire
    const p2 = LatLng(-23.5601, -46.6575); // Alameda Santos

    final distance = DriverLocationService.calculateDistanceMeters(p1, p2);
    // Around 1250 - 1300 meters apart in direct line
    expect(distance, inInclusiveRange(1200.0, 1400.0));
  });

  test(
    'simulation mode emits telemetry updates and detects proximity to stop',
    () async {
      final service = DriverLocationService(allowSimulation: true);

      const stop1 = RouteStop(
        id: 'stop-01',
        kind: StopKind.home,
        position: 1000,
        name: 'Lucas Alencar',
        address: 'Rua Oscar Freire, 1000',
        latitude: -23.5615,
        longitude: -46.6698,
      );
      // A school registered without coordinates cannot drive proximity.
      const unmappedSchool = RouteStop(
        id: 'school-no-coords',
        kind: StopKind.school,
        position: 1,
        name: 'Escola',
        address: '',
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
        pendingStops: [unmappedSchool, stop1],
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
      expect(updates.every((u) => u.isSimulated), isTrue);

      // Check that point 1 triggered proximity (< 50m) to stop1
      final nearStopUpdate = updates.firstWhere((u) => u.isApproachingStop);
      expect(nearStopUpdate.approachingStop?.id, 'stop-01');
      expect(nearStopUpdate.distanceToNextStopMeters, lessThan(50.0));
    },
  );

  group('device GPS', () {
    const route = [LatLng(-23.57, -46.675), LatLng(-23.5745, -46.6405)];

    test('denied permission never falls back to simulation', () async {
      final geo = FakeGeolocator(permission: LocationPermission.denied);
      final service = DriverLocationService(geolocator: geo);
      final updates = <VanTelemetryUpdate>[];
      final sub = service.telemetryStream.listen(updates.add);

      final result = await service.startTracking(routePoints: route);
      await Future<void>.delayed(const Duration(milliseconds: 1100));

      expect(result, GpsAvailability.denied);
      expect(service.availability.value, GpsAvailability.denied);
      expect(service.isTracking, isFalse);
      expect(service.mode, LocationTrackingMode.deviceGps);
      expect(updates, isEmpty);
      await sub.cancel();
      service.dispose();
    });

    test('reports disabled services and permanent denial', () async {
      final off = DriverLocationService(
        geolocator: FakeGeolocator(serviceEnabled: false),
      );
      expect(
        await off.startTracking(routePoints: route),
        GpsAvailability.serviceDisabled,
      );
      final forever = DriverLocationService(
        geolocator: FakeGeolocator(
          permission: LocationPermission.deniedForever,
        ),
      );
      expect(
        await forever.startTracking(routePoints: route),
        GpsAvailability.deniedForever,
      );
      off.dispose();
      forever.dispose();
    });

    test('simulation is refused unless explicitly allowed', () async {
      final service = DriverLocationService(geolocator: FakeGeolocator());

      expect(service.allowSimulation, isFalse);
      expect(
        () => service.startTracking(
          routePoints: route,
          mode: LocationTrackingMode.simulation,
        ),
        throwsStateError,
      );
      service.dispose();
    });

    test('real fixes emit non-simulated samples with capture data', () async {
      final geo = FakeGeolocator();
      final service = DriverLocationService(geolocator: geo);
      final updates = <VanTelemetryUpdate>[];
      final sub = service.telemetryStream.listen(updates.add);

      expect(
        await service.startTracking(routePoints: route),
        GpsAvailability.available,
      );
      final fixAt = DateTime.utc(2026, 10, 5, 9, 0, 3);
      geo.positions.add(position(fixAt));
      await Future<void>.delayed(Duration.zero);

      expect(service.isTracking, isTrue);
      expect(updates.single.isSimulated, isFalse);
      expect(updates.single.timestamp, fixAt);
      expect(updates.single.accuracyMeters, 6);
      await sub.cancel();
      service.dispose();
    });

    test('a GPS stream error is reported as unavailable', () async {
      final geo = FakeGeolocator();
      final service = DriverLocationService(geolocator: geo);
      await service.startTracking(routePoints: route);

      geo.positions.addError(Exception('sensor'));
      await Future<void>.delayed(Duration.zero);

      expect(service.availability.value, GpsAvailability.error);
      expect(service.isTracking, isFalse);
      service.dispose();
    });
  });
}

Position position(DateTime at) => Position(
  latitude: -23.56,
  longitude: -46.66,
  timestamp: at,
  accuracy: 6,
  altitude: 0,
  altitudeAccuracy: 0,
  heading: 45,
  headingAccuracy: 0,
  speed: 10,
  speedAccuracy: 0,
);

/// In-memory geolocator: fixed permission state and a controllable stream.
class FakeGeolocator extends GeolocatorPlatform {
  FakeGeolocator({
    this.serviceEnabled = true,
    this.permission = LocationPermission.whileInUse,
  });

  final bool serviceEnabled;
  final LocationPermission permission;
  final positions = StreamController<Position>.broadcast();

  @override
  Future<bool> isLocationServiceEnabled() async => serviceEnabled;

  @override
  Future<LocationPermission> checkPermission() async => permission;

  @override
  Future<LocationPermission> requestPermission() async => permission;

  @override
  Stream<Position> getPositionStream({LocationSettings? locationSettings}) =>
      positions.stream;
}
