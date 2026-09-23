import 'package:latlong2/latlong.dart';

import 'route_stop.dart';

enum TripStatus {
  scheduled,
  inProgress,
  completed,
}

class DriverTrip {
  const DriverTrip({
    required this.id,
    required this.title,
    required this.vanPlate,
    required this.shift,
    required this.stops,
    this.status = TripStatus.scheduled,
    this.polylinePoints = const [],
    this.totalDistanceMeters = 0,
    this.totalDurationSeconds = 0,
  });

  final String id;
  final String title;
  final String vanPlate;
  final String shift;
  final TripStatus status;
  final List<RouteStop> stops;
  final List<LatLng> polylinePoints;
  final double totalDistanceMeters;
  final double totalDurationSeconds;

  int get totalStudents =>
      stops.where((s) => s.type == StopType.pickup).length;

  int get completedStudentsCount => stops
      .where((s) => s.type == StopType.pickup && s.isCompleted)
      .length;

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
    String? id,
    String? title,
    String? vanPlate,
    String? shift,
    TripStatus? status,
    List<RouteStop>? stops,
    List<LatLng>? polylinePoints,
    double? totalDistanceMeters,
    double? totalDurationSeconds,
  }) {
    return DriverTrip(
      id: id ?? this.id,
      title: title ?? this.title,
      vanPlate: vanPlate ?? this.vanPlate,
      shift: shift ?? this.shift,
      status: status ?? this.status,
      stops: stops ?? this.stops,
      polylinePoints: polylinePoints ?? this.polylinePoints,
      totalDistanceMeters: totalDistanceMeters ?? this.totalDistanceMeters,
      totalDurationSeconds: totalDurationSeconds ?? this.totalDurationSeconds,
    );
  }
}
