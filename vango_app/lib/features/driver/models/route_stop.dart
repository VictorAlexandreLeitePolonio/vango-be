enum StopType {
  pickup,
  dropoff,
}

enum StopStatus {
  pending,
  boarded,
  completed,
  absent,
}

class RouteStop {
  const RouteStop({
    required this.id,
    required this.name,
    required this.address,
    required this.scheduledTime,
    required this.latitude,
    required this.longitude,
    required this.type,
    this.status = StopStatus.pending,
    this.notes,
  });

  final String id;
  final String name;
  final String address;
  final String scheduledTime;
  final double latitude;
  final double longitude;
  final StopType type;
  final StopStatus status;
  final String? notes;

  bool get isCompleted =>
      status == StopStatus.boarded ||
      status == StopStatus.completed ||
      status == StopStatus.absent;

  bool get isSchoolDestination => type == StopType.dropoff;

  RouteStop copyWith({
    String? id,
    String? name,
    String? address,
    String? scheduledTime,
    double? latitude,
    double? longitude,
    StopType? type,
    StopStatus? status,
    String? notes,
  }) {
    return RouteStop(
      id: id ?? this.id,
      name: name ?? this.name,
      address: address ?? this.address,
      scheduledTime: scheduledTime ?? this.scheduledTime,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      type: type ?? this.type,
      status: status ?? this.status,
      notes: notes ?? this.notes,
    );
  }
}
