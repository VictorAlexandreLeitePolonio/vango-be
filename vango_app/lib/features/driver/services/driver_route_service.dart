import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/driver_trip.dart';
import '../models/route_stop.dart';
import 'mapbox_directions_service.dart';

/// Reads persisted trips through the role-safe `list_service_day` and
/// `get_trip` RPCs and computes route geometry for the loaded trip.
///
/// Backend failures propagate as [PostgrestException] (stable `code`); there
/// is no fallback trip.
class DriverRouteService {
  DriverRouteService({
    SupabaseClient? client,
    MapboxDirectionsService? directionsService,
  }) : _client = client ?? Supabase.instance.client,
       _directionsService = directionsService ?? MapboxDirectionsService();

  final SupabaseClient _client;
  final MapboxDirectionsService _directionsService;

  DriverTrip? _currentTrip;

  /// Authenticated user id, used to decide who may operate a trip.
  String? get currentUserId => _client.auth.currentUser?.id;

  /// Lists the service-day trips of every fleet in [fleetIds] for the local
  /// calendar day of [serviceDate], ordered by planned start.
  ///
  /// Owners receive every fleet trip and drivers only their own; the backend
  /// decides, so this never filters by role.
  Future<List<DriverTrip>> listTrips({
    required List<String> fleetIds,
    required DateTime serviceDate,
  }) async {
    final date = _isoDate(serviceDate);
    final trips = <DriverTrip>[];
    for (final fleetId in fleetIds) {
      final day = await _client.rpc(
        'list_service_day',
        params: {'p_fleet_id': fleetId, 'p_service_date': date},
      );
      if (day is! Map || day['trips'] is! List) {
        throw const FormatException('Invalid service day');
      }
      for (final trip in day['trips'] as List) {
        if (trip is! Map) throw const FormatException('Invalid trip');
        trips.add(DriverTrip.fromProjection(Map<String, dynamic>.from(trip)));
      }
    }
    trips.sort((a, b) => a.plannedStartAt.compareTo(b.plannedStartAt));
    return trips;
  }

  /// Loads one authorized trip and makes it the current trip of this service.
  Future<DriverTrip> getTrip(String tripId) async {
    final json = await _client.rpc('get_trip', params: {'p_trip_id': tripId});
    if (json is! Map) throw const FormatException('Invalid trip');
    _currentTrip = DriverTrip.fromProjection(Map<String, dynamic>.from(json));
    return _currentTrip!;
  }

  /// Calculates route geometry and duration via Mapbox for the loaded trip,
  /// through the stops that have coordinates, in backend order.
  Future<DriverTrip> calculateAndOptimizeRoute({
    bool forceRefresh = false,
  }) async {
    final trip = _requireTrip();
    final coords = trip.mappableStops
        .map((s) => LatLng(s.latitude!, s.longitude!))
        .toList();

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

  // The lifecycle methods below are still local-only; task 21 replaces them
  // with the idempotent start_trip / record_passenger_event / finish_trip RPCs.

  Future<DriverTrip> startTrip() async {
    _currentTrip = _requireTrip().copyWith(status: TripStatus.active);
    return _currentTrip!;
  }

  Future<DriverTrip> updateStopStatus(
    String stopId,
    StopStatus newStatus,
  ) async {
    final trip = _requireTrip();
    _currentTrip = trip.copyWith(
      stops: [
        for (final stop in trip.stops)
          stop.id == stopId ? stop.copyWith(status: newStatus) : stop,
      ],
    );
    return _currentTrip!;
  }

  Future<DriverTrip> finishTrip() async {
    final trip = _requireTrip();
    _currentTrip = trip.copyWith(
      status: TripStatus.completed,
      stops: [
        for (final stop in trip.stops)
          stop.isSchoolDestination
              ? stop.copyWith(status: StopStatus.reached)
              : stop,
      ],
    );
    return _currentTrip!;
  }

  DriverTrip _requireTrip() {
    final trip = _currentTrip;
    if (trip == null) throw StateError('Load a trip before operating it');
    return trip;
  }

  static String _isoDate(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
}
