import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../models/route_stop.dart';

enum LocationTrackingMode {
  deviceGps,
  simulation,
}

class VanTelemetryUpdate {
  const VanTelemetryUpdate({
    required this.position,
    required this.headingDegrees,
    required this.speedKmh,
    required this.timestamp,
    this.distanceToNextStopMeters,
    this.approachingStop,
    this.simulationProgressPercent,
  });

  final LatLng position;
  final double headingDegrees;
  final double speedKmh;
  final DateTime timestamp;
  final double? distanceToNextStopMeters;
  final RouteStop? approachingStop;
  final double? simulationProgressPercent; // 0.0 to 1.0

  bool get isApproachingStop => approachingStop != null;
}

class DriverLocationService {
  DriverLocationService();

  final _telemetryController = StreamController<VanTelemetryUpdate>.broadcast();
  Stream<VanTelemetryUpdate> get telemetryStream => _telemetryController.stream;

  LocationTrackingMode _mode = LocationTrackingMode.simulation;
  LocationTrackingMode get mode => _mode;

  Timer? _simulationTimer;
  StreamSubscription<Position>? _gpsSubscription;

  List<LatLng> _routePoints = [];
  List<RouteStop> _pendingStops = [];
  int _simulationIndex = 0;
  VanTelemetryUpdate? _latestTelemetry;
  VanTelemetryUpdate? get latestTelemetry => _latestTelemetry;

  bool _isTracking = false;
  bool get isTracking => _isTracking;

  /// Check and request location permission on the device
  Future<bool> checkAndRequestPermissions() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        debugPrint('[DriverLocation] ⚠️ Serviços de localização desativados no dispositivo.');
        return false;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          debugPrint('[DriverLocation] ⚠️ Permissão de localização negada pelo usuário.');
          return false;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        debugPrint('[DriverLocation] ⚠️ Permissão de localização negada permanentemente.');
        return false;
      }

      return true;
    } catch (e) {
      debugPrint('[DriverLocation] ⚠️ Erro ao verificar permissões de GPS: $e');
      return false;
    }
  }

  /// Start tracking (GPS or Simulation)
  Future<void> startTracking({
    required List<LatLng> routePoints,
    List<RouteStop> pendingStops = const [],
    LocationTrackingMode mode = LocationTrackingMode.simulation,
  }) async {
    stopTracking();

    _routePoints = List.from(routePoints);
    _pendingStops = List.from(pendingStops);
    _mode = mode;
    _isTracking = true;

    if (_mode == LocationTrackingMode.deviceGps) {
      final granted = await checkAndRequestPermissions();
      if (!granted) {
        debugPrint('[DriverLocation] 🔄 Sem permissão GPS nativa. Alternando para modo Simulação.');
        _mode = LocationTrackingMode.simulation;
        _startSimulation();
        return;
      }
      _startDeviceGps();
    } else {
      _startSimulation();
    }
  }

  void updatePendingStops(List<RouteStop> stops) {
    _pendingStops = List.from(stops);
    if (_latestTelemetry != null) {
      _evaluateProximityAndEmit(_latestTelemetry!.position, _latestTelemetry!.headingDegrees, _latestTelemetry!.speedKmh);
    }
  }

  void _startSimulation() {
    if (_routePoints.isEmpty) return;

    _simulationIndex = 0;
    const interval = Duration(milliseconds: 1000);

    _simulationTimer = Timer.periodic(interval, (timer) {
      if (_simulationIndex >= _routePoints.length) {
        timer.cancel();
        _isTracking = false;
        return;
      }

      final current = _routePoints[_simulationIndex];
      double heading = 0.0;

      if (_simulationIndex < _routePoints.length - 1) {
        final next = _routePoints[_simulationIndex + 1];
        heading = calculateBearing(current, next);
      } else if (_simulationIndex > 0) {
        final prev = _routePoints[_simulationIndex - 1];
        heading = calculateBearing(prev, current);
      }

      final progress = (_simulationIndex + 1) / _routePoints.length;
      _evaluateProximityAndEmit(
        current,
        heading,
        35.0, // 35 km/h simulated driving speed
        simulationProgress: progress,
      );

      _simulationIndex++;
    });
  }

  void _startDeviceGps() {
    const locationSettings = LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 5, // Emite a cada 5 metros percorridos
    );

    _gpsSubscription = Geolocator.getPositionStream(
      locationSettings: locationSettings,
    ).listen(
      (Position position) {
        final latLng = LatLng(position.latitude, position.longitude);
        final heading = position.heading.isFinite && position.heading >= 0
            ? position.heading
            : (_latestTelemetry?.headingDegrees ?? 0.0);
        final speedKmh = position.speed >= 0 ? position.speed * 3.6 : 0.0;

        _evaluateProximityAndEmit(latLng, heading, speedKmh);
      },
      onError: (error) {
        debugPrint('[DriverLocation] ❌ Erro no stream de GPS: $error');
      },
    );
  }

  void _evaluateProximityAndEmit(
    LatLng currentPos,
    double heading,
    double speedKmh, {
    double? simulationProgress,
  }) {
    double? minDistance;
    RouteStop? nextStop;

    if (_pendingStops.isNotEmpty) {
      nextStop = _pendingStops.first;
      final stopPos = LatLng(nextStop.latitude, nextStop.longitude);
      minDistance = calculateDistanceMeters(currentPos, stopPos);
    }

    // Stop approaching trigger (< 50 meters)
    final approaching = (minDistance != null && minDistance < 50.0) ? nextStop : null;

    final telemetry = VanTelemetryUpdate(
      position: currentPos,
      headingDegrees: heading,
      speedKmh: speedKmh,
      timestamp: DateTime.now(),
      distanceToNextStopMeters: minDistance,
      approachingStop: approaching,
      simulationProgressPercent: simulationProgress,
    );

    _latestTelemetry = telemetry;
    if (!_telemetryController.isClosed) {
      _telemetryController.add(telemetry);
    }
  }

  void stopTracking() {
    _simulationTimer?.cancel();
    _simulationTimer = null;
    _gpsSubscription?.cancel();
    _gpsSubscription = null;
    _isTracking = false;
  }

  void dispose() {
    stopTracking();
    _telemetryController.close();
  }

  /// Calculates azimuth bearing (in degrees: 0° = North, 90° = East, etc.)
  static double calculateBearing(LatLng start, LatLng end) {
    final startLat = _degreesToRadians(start.latitude);
    final startLng = _degreesToRadians(start.longitude);
    final endLat = _degreesToRadians(end.latitude);
    final endLng = _degreesToRadians(end.longitude);

    final dLng = endLng - startLng;
    final y = math.sin(dLng) * math.cos(endLat);
    final x = math.cos(startLat) * math.sin(endLat) -
        math.sin(startLat) * math.cos(endLat) * math.cos(dLng);

    final bearingRad = math.atan2(y, x);
    return (_radiansToDegrees(bearingRad) + 360.0) % 360.0;
  }

  /// Calculates distance in meters between two coordinates via Haversine formula
  static double calculateDistanceMeters(LatLng p1, LatLng p2) {
    const distance = Distance();
    return distance.as(LengthUnit.Meter, p1, p2);
  }

  static double _degreesToRadians(double degrees) => degrees * (math.pi / 180.0);
  static double _radiansToDegrees(double radians) => radians * (180.0 / math.pi);
}
