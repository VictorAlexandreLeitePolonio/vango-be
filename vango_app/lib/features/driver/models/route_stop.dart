/// Backend `trip_stops.kind` values.
enum StopKind { origin, home, school, destination }

/// Backend `record_passenger_event` kinds for the trip lifecycle.
enum PassengerEventKind {
  boarded('boarded'),
  absent('absent'),
  droppedOff('dropped_off');

  const PassengerEventKind(this.backend);

  /// Exact backend string sent in the RPC payload.
  final String backend;
}

/// Operational state of a stop.
///
/// Home stops mirror the passenger `operation_status`; origin, school and
/// destination stops only know whether the van reached them (`reached_at`).
enum StopStatus { pending, boarded, droppedOff, absent, reached }

/// A persisted trip stop from the authorized `get_trip` projection.
class RouteStop {
  const RouteStop({
    required this.id,
    required this.kind,
    required this.position,
    required this.name,
    required this.address,
    this.latitude,
    this.longitude,
    this.studentId,
    this.status = StopStatus.pending,
  });

  final String id;
  final StopKind kind;

  /// Backend ordering key; stops are always shown in ascending position.
  final int position;
  final String name;
  final String address;

  /// Schools may be registered without coordinates, so both are optional.
  final double? latitude;
  final double? longitude;
  final String? studentId;
  final StopStatus status;

  bool get hasCoordinates => latitude != null && longitude != null;

  bool get isCompleted => status != StopStatus.pending;

  bool get isSchoolDestination =>
      kind == StopKind.school || kind == StopKind.destination;
}
