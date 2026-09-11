import 'package:latlong2/latlong.dart';

import '../models/driver_trip.dart';
import '../models/route_stop.dart';
import 'mapbox_directions_service.dart';

import '../../fleet/services/fleet_service.dart';

class DriverRouteService {
  DriverRouteService({
    MapboxDirectionsService? directionsService,
    FleetService? fleetService,
  })  : _directionsService = directionsService ?? MapboxDirectionsService(),
        _fleetService = fleetService ?? FleetService();

  final MapboxDirectionsService _directionsService;
  final FleetService _fleetService;

  DriverTrip? _currentTrip;

  /// Default 3 stops with real coordinates in São Paulo:
  /// 2 student pickups + 1 school/university destination.
  static const List<RouteStop> defaultStops = [
    RouteStop(
      id: 'stop-01-lucas',
      name: 'Lucas Alencar',
      address: 'Rua Oscar Freire, 1000 - Cerqueira César',
      scheduledTime: '06:45',
      latitude: -23.5615,
      longitude: -46.6698,
      type: StopType.pickup,
      notes: 'Aguardar no portão principal',
    ),
    RouteStop(
      id: 'stop-02-mariana',
      name: 'Mariana Rios',
      address: 'Alameda Santos, 1800 - Cerqueira César',
      scheduledTime: '07:05',
      latitude: -23.5601,
      longitude: -46.6575,
      type: StopType.pickup,
      notes: 'Tocar interfone 32',
    ),
    RouteStop(
      id: 'stop-03-colegio',
      name: 'Colégio Objetivo / Campus Central',
      address: 'Rua Vergueiro, 1200 - Paraíso',
      scheduledTime: '07:30',
      latitude: -23.5745,
      longitude: -46.6405,
      type: StopType.dropoff,
      notes: 'Entrada de vans pelo portão B',
    ),
  ];

  DriverTrip get initialTrip => const DriverTrip(
        id: 'trip-today-001',
        title: 'Rota Matutina — Colégio Objetivo',
        vanPlate: 'BRA-2E19',
        shift: 'Manhã',
        stops: defaultStops,
      );

  Future<DriverTrip> getTodayTrip() async {
    if (_currentTrip != null) return _currentTrip!;

    final enrolled = await _fleetService.getEnrolledStudents('51000000-0000-0000-0000-000000000001');
    if (enrolled.isNotEmpty) {
      final stops = <RouteStop>[];
      int minute = 45;
      for (int i = 0; i < enrolled.length; i++) {
        final st = enrolled[i];
        final timeStr = '06:${minute.toString().padLeft(2, '0')}';
        minute += 15;
        stops.add(
          RouteStop(
            id: st.id,
            name: st.fullName,
            address: st.address,
            scheduledTime: timeStr,
            latitude: st.latitude,
            longitude: st.longitude,
            type: StopType.pickup,
          ),
        );
      }

      // Escola de destino final
      stops.add(
        const RouteStop(
          id: 'stop-03-colegio',
          name: 'Colégio Objetivo / Campus Central',
          address: 'Rua Vergueiro, 1200 - Paraíso',
          scheduledTime: '07:30',
          latitude: -23.5745,
          longitude: -46.6405,
          type: StopType.dropoff,
          notes: 'Portão principal de vans escolares',
        ),
      );

      _currentTrip = DriverTrip(
        id: 'trip-today-001',
        title: 'Rota Matutina — Colégio Objetivo',
        vanPlate: 'BRA-2E19',
        shift: 'Manhã',
        stops: stops,
      );
      return _currentTrip!;
    }

    _currentTrip = initialTrip;
    return _currentTrip!;
  }

  /// Calculates the optimized route geometry and real duration via Mapbox.
  /// Uses cached results to strictly avoid redundant API requests.
  Future<DriverTrip> calculateAndOptimizeRoute({bool forceRefresh = false}) async {
    final trip = await getTodayTrip();

    final coords = trip.stops.map((s) => LatLng(s.latitude, s.longitude)).toList();

    if (forceRefresh) {
      MapboxDirectionsService.clearCache();
    }

    final directions = await _directionsService.getDrivingRoute(
      cacheKey: trip.id,
      coordinates: coords,
    );

    _currentTrip = trip.copyWith(
      polylinePoints: directions.polylinePoints,
      totalDistanceMeters: directions.totalDistanceMeters,
      totalDurationSeconds: directions.totalDurationSeconds,
    );

    return _currentTrip!;
  }

  Future<DriverTrip> startTrip() async {
    final trip = await getTodayTrip();
    _currentTrip = trip.copyWith(status: TripStatus.inProgress);
    return _currentTrip!;
  }

  Future<DriverTrip> updateStopStatus(String stopId, StopStatus newStatus) async {
    final trip = await getTodayTrip();
    final updatedStops = trip.stops.map((stop) {
      if (stop.id == stopId) {
        return stop.copyWith(status: newStatus);
      }
      return stop;
    }).toList();

    _currentTrip = trip.copyWith(stops: updatedStops);
    return _currentTrip!;
  }

  Future<DriverTrip> finishTrip() async {
    final trip = await getTodayTrip();
    final updatedStops = trip.stops.map((stop) {
      if (stop.isSchoolDestination) {
        return stop.copyWith(status: StopStatus.completed);
      }
      return stop;
    }).toList();

    _currentTrip = trip.copyWith(
      status: TripStatus.completed,
      stops: updatedStops,
    );
    return _currentTrip!;
  }

  void resetForTest() {
    _currentTrip = null;
    MapboxDirectionsService.clearCache();
  }
}
