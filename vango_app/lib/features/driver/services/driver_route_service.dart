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
  ///
  /// Reloading the same trip (after every lifecycle command) keeps the route
  /// geometry already computed for it, so the map does not lose its polyline.
  Future<DriverTrip> getTrip(String tripId) async {
    final json = await _client.rpc('get_trip', params: {'p_trip_id': tripId});
    if (json is! Map) throw const FormatException('Invalid trip');
    final previous = _currentTrip;
    var trip = DriverTrip.fromProjection(Map<String, dynamic>.from(json));
    if (previous != null && previous.id == trip.id) {
      trip = trip.copyWith(
        polylinePoints: previous.polylinePoints,
        totalDistanceMeters: previous.totalDistanceMeters,
        totalDurationSeconds: previous.totalDurationSeconds,
      );
    }
    _currentTrip = trip;
    return trip;
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

  /// Starts the trip through the idempotent backend command and returns the
  /// freshly loaded persisted trip.
  Future<DriverTrip> startTrip(String tripId, String commandId) async {
    await _client.rpc(
      'start_trip',
      params: {'p_trip_id': tripId, 'p_command_id': commandId},
    );
    return getTrip(tripId);
  }

  /// Records one passenger lifecycle event through the backend command and
  /// returns the freshly loaded persisted trip.
  Future<DriverTrip> recordPassengerEvent(
    String tripId,
    String studentId,
    PassengerEventKind kind,
    String commandId,
  ) async {
    await _client.rpc(
      'record_passenger_event',
      params: {
        'p_trip_id': tripId,
        'p_student_id': studentId,
        'p_kind': kind.backend,
        'p_command_id': commandId,
      },
    );
    return getTrip(tripId);
  }

  /// Marks the van as arrived at one trip stop and returns the freshly loaded
  /// persisted trip.
  Future<DriverTrip> markStopReached(
    String tripId,
    String stopId,
    String commandId,
  ) async {
    await _client.rpc(
      'mark_trip_stop_reached',
      params: {'p_stop_id': stopId, 'p_command_id': commandId},
    );
    return getTrip(tripId);
  }

  /// Finishes the trip (no cancellation in the MVP) and returns the freshly
  /// loaded persisted trip.
  Future<DriverTrip> finishTrip(String tripId, String commandId) async {
    await _client.rpc(
      'finish_trip',
      params: {
        'p_trip_id': tripId,
        'p_cancel': false,
        'p_reason': null,
        'p_command_id': commandId,
      },
    );
    return getTrip(tripId);
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
