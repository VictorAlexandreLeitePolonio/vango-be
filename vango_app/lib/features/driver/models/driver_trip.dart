import 'package:latlong2/latlong.dart';

import 'route_stop.dart';

/// Backend `trips.status` values.
enum TripStatus {
  scheduled,
  confirmationClosed,
  active,
  completed,
  cancelled;

  /// Parses a backend status; unknown values fail instead of being guessed.
  static TripStatus fromBackend(String value) => switch (value) {
    'scheduled' => scheduled,
    'confirmation_closed' => confirmationClosed,
    'active' => active,
    'completed' => completed,
    'cancelled' => cancelled,
    _ => throw FormatException('Unknown trip status: $value'),
  };

  bool get isTerminal => this == completed || this == cancelled;
}

/// A persisted trip read from the authorized `get_trip` projection.
class DriverTrip {
  const DriverTrip({
    required this.id,
    required this.fleetId,
    required this.routeName,
    required this.vanPlate,
    required this.driverUserId,
    required this.plannedStartAt,
    required this.stops,
    this.status = TripStatus.scheduled,
    this.startedAt,
    this.assignments = const [],
    this.polylinePoints = const [],
    this.totalDistanceMeters = 0,
    this.totalDurationSeconds = 0,
  });

  /// Maps the owner/driver `get_trip` JSON (`{trip, passengers, stops, ...}`).
  ///
  /// Stops keep the backend `position` order. Home stops take the passenger's
  /// name and operation status; passengers that were removed, declined or
  /// expired are not operable and their home stops are dropped.
  factory DriverTrip.fromProjection(Map<String, dynamic> json) {
    final trip = _map(json['trip'], 'trip');

    final passengersByStudent = <String, Map<String, dynamic>>{};
    for (final raw in _list(json['passengers'], 'passengers')) {
      final passenger = _map(raw, 'passenger');
      final operable =
          passenger['removed_at'] == null &&
          !const {
            'declined',
            'expired',
          }.contains(passenger['confirmation_status']);
      if (operable) {
        passengersByStudent[_string(passenger, 'student_id')] = passenger;
      }
    }

    final stops = <RouteStop>[];
    for (final raw in _list(json['stops'], 'stops')) {
      final stop = _map(raw, 'stop');
      final kind = _stopKind(_string(stop, 'kind'));
      final snapshot = stop['address_snapshot'] is Map
          ? Map<String, dynamic>.from(stop['address_snapshot'] as Map)
          : const <String, dynamic>{};
      final reached = stop['reached_at'] != null;

      String name;
      String address;
      String? studentId;
      var status = reached ? StopStatus.reached : StopStatus.pending;
      switch (kind) {
        case StopKind.home:
          studentId = _string(stop, 'student_id');
          final passenger = passengersByStudent[studentId];
          if (passenger == null) continue;
          name = (passenger['student_full_name'] as String?) ?? 'Aluno';
          address = _formatAddress(snapshot);
          status = _passengerStatus(_string(passenger, 'operation_status'));
        case StopKind.school:
          name = (snapshot['name'] as String?) ?? 'Escola';
          address = _formatAddress(snapshot);
        case StopKind.origin:
          name = 'Partida';
          address = (snapshot['label'] as String?) ?? '';
        case StopKind.destination:
          name = 'Destino';
          address = (snapshot['label'] as String?) ?? '';
      }

      stops.add(
        RouteStop(
          id: _string(stop, 'id'),
          kind: kind,
          position: (stop['position'] as num).toInt(),
          name: name,
          address: address,
          latitude: (stop['latitude'] as num?)?.toDouble(),
          longitude: (stop['longitude'] as num?)?.toDouble(),
          studentId: studentId,
          status: status,
        ),
      );
    }
    stops.sort((a, b) => a.position.compareTo(b.position));

    return DriverTrip(
      id: _string(trip, 'id'),
      fleetId: _string(trip, 'fleet_id'),
      routeName: (trip['route_name'] as String?) ?? 'Rota',
      vanPlate: (trip['van_plate'] as String?) ?? '',
      driverUserId: trip['driver_user_id'] as String?,
      plannedStartAt: DateTime.parse(_string(trip, 'planned_start_at')),
      status: TripStatus.fromBackend(_string(trip, 'status')),
      startedAt: trip['started_at'] == null
          ? null
          : DateTime.parse(trip['started_at'] as String),
      assignments: [
        for (final raw in (json['assignments'] as List?) ?? const [])
          _map(raw, 'assignment'),
      ],
      stops: stops,
    );
  }

  final String id;
  final String fleetId;
  final String routeName;
  final String vanPlate;

  /// Assigned operator; only this user may run the trip.
  final String? driverUserId;
  final DateTime plannedStartAt;
  final TripStatus status;

  /// When the trip went `active`; telemetry sequences are offsets from it.
  final DateTime? startedAt;

  /// Raw `trip_assignments` rows (`id`, `driver_user_id`, `valid_until`, ...).
  final List<Map<String, dynamic>> assignments;
  final List<RouteStop> stops;
  final List<LatLng> polylinePoints;
  final double totalDistanceMeters;
  final double totalDurationSeconds;

  /// Whether [userId] may operate this trip. Owners see every fleet trip but
  /// only the assigned driver gets the operate action; the backend enforces it.
  bool isOperableBy(String? userId) =>
      userId != null && userId == driverUserId && !status.isTerminal;

  /// Id of the open assignment (`valid_until == null`) held by [userId], the
  /// assignment telemetry must be ingested under; null when there is none.
  String? currentAssignmentIdFor(String? userId) {
    if (userId == null) return null;
    for (final a in assignments) {
      if (a['valid_until'] == null && a['driver_user_id'] == userId) {
        return a['id'] as String?;
      }
    }
    return null;
  }

  /// Stops that can be drawn on the map and routed through.
  List<RouteStop> get mappableStops =>
      stops.where((s) => s.hasCoordinates).toList();

  /// True when home stops come before the school stop (going direction);
  /// trips without home stops are treated as outbound.
  bool get isOutbound {
    final firstHome = stops.where((s) => s.kind == StopKind.home).firstOrNull;
    final school = schoolStop;
    if (firstHome == null || school == null) return true;
    return firstHome.position < school.position;
  }

  /// The first school stop, when the trip has one.
  RouteStop? get schoolStop {
    for (final stop in stops) {
      if (stop.kind == StopKind.school) return stop;
    }
    return null;
  }

  /// The stop the driver must act on next; origin and destination are never
  /// action stops (the MVP does not mark them).
  ///
  /// Outbound: the first still-pending home stop, then the school. Return:
  /// the school, then the first boarded home stop waiting for drop-off.
  RouteStop? get nextActionStop {
    if (!isOutbound) {
      final school = schoolStop;
      if (school != null && school.status != StopStatus.reached) return school;
      for (final stop in stops) {
        if (stop.kind == StopKind.home && stop.status == StopStatus.boarded) {
          return stop;
        }
      }
      return null;
    }
    for (final stop in stops) {
      if (stop.kind == StopKind.home && stop.status == StopStatus.pending) {
        return stop;
      }
    }
    final school = schoolStop;
    if (school != null && school.status != StopStatus.reached) return school;
    return null;
  }

  /// True when the trip is active and every home stop is resolved as a
  /// drop-off or an absence.
  bool get canFinish =>
      status == TripStatus.active &&
      stops
          .where((s) => s.kind == StopKind.home)
          .every(
            (s) =>
                s.status == StopStatus.droppedOff ||
                s.status == StopStatus.absent,
          );

  int get totalStudents => stops.where((s) => s.kind == StopKind.home).length;

  int get completedStudentsCount =>
      stops.where((s) => s.kind == StopKind.home && s.isCompleted).length;

  RouteStop? get nextPendingStop {
    for (final stop in stops) {
      if (!stop.isCompleted) return stop;
    }
    return null;
  }

  List<RouteStop> get pendingStops =>
      stops.where((s) => !s.isCompleted).toList();

  bool get isAllStopsCompleted => stops.every((s) => s.isCompleted);

  String get formattedDistance {
    if (totalDistanceMeters <= 0) return '-- km';
    final km = totalDistanceMeters / 1000.0;
    return '${km.toStringAsFixed(1)} km';
  }

  String get formattedDuration {
    if (totalDurationSeconds <= 0) return '-- min';
    final minutes = (totalDurationSeconds / 60.0).round();
    return '$minutes min';
  }

  DriverTrip copyWith({
    TripStatus? status,
    List<RouteStop>? stops,
    List<LatLng>? polylinePoints,
    double? totalDistanceMeters,
    double? totalDurationSeconds,
  }) {
    return DriverTrip(
      id: id,
      fleetId: fleetId,
      routeName: routeName,
      vanPlate: vanPlate,
      driverUserId: driverUserId,
      plannedStartAt: plannedStartAt,
      status: status ?? this.status,
      startedAt: startedAt,
      assignments: assignments,
      stops: stops ?? this.stops,
      polylinePoints: polylinePoints ?? this.polylinePoints,
      totalDistanceMeters: totalDistanceMeters ?? this.totalDistanceMeters,
      totalDurationSeconds: totalDurationSeconds ?? this.totalDurationSeconds,
    );
  }

  static StopKind _stopKind(String value) => switch (value) {
    'origin' => StopKind.origin,
    'home' => StopKind.home,
    'school' => StopKind.school,
    'destination' => StopKind.destination,
    _ => throw FormatException('Unknown stop kind: $value'),
  };

  static StopStatus _passengerStatus(String value) => switch (value) {
    'waiting' => StopStatus.pending,
    'boarded' => StopStatus.boarded,
    'dropped_off' => StopStatus.droppedOff,
    'absent' => StopStatus.absent,
    _ => throw FormatException('Unknown passenger status: $value'),
  };

  /// "Street, number - neighborhood, city", skipping missing parts.
  static String _formatAddress(Map<String, dynamic> snapshot) {
    String? part(String key) {
      final value = snapshot[key];
      return value is String && value.trim().isNotEmpty ? value.trim() : null;
    }

    final street = [
      part('street'),
      part('street_number'),
    ].whereType<String>().join(', ');
    final area = [
      part('neighborhood'),
      part('city_name'),
    ].whereType<String>().join(', ');
    return [street, area].where((s) => s.isNotEmpty).join(' - ');
  }

  static Map<String, dynamic> _map(Object? value, String field) {
    if (value is! Map) throw FormatException('Invalid $field');
    return Map<String, dynamic>.from(value);
  }

  static List<Object?> _list(Object? value, String field) {
    if (value is! List) throw FormatException('Invalid $field');
    return value;
  }

  static String _string(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is! String || value.isEmpty) {
      throw FormatException('Invalid $key');
    }
    return value;
  }
}
