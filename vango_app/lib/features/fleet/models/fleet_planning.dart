/// A malformed known field in the planning API response.
class PlanningResponseFormatException extends FormatException {
  const PlanningResponseFormatException(String field)
    : super('Invalid planning field: $field');
}

/// An explicitly selected geographic point with an owner-visible label.
typedef PlanningPoint = ({double latitude, double longitude, String label});

/// Editable vehicle configuration and its opaque revision.
typedef PlanningVan = ({
  String id,
  String plate,
  String model,
  String publicName,
  int capacity,
  String status,
  int editRevision,
});

/// Ordered institution reference on a route.
typedef PlanningRouteSchool = ({String schoolId, int position});

/// Editable route configuration, separate from routing computation versions.
typedef PlanningRoute = ({
  String id,
  String name,
  String direction,
  String shift,
  String? pairedRouteId,
  String vanId,
  String driverUserId,
  int proximityMinutes,
  PlanningPoint origin,
  PlanningPoint destination,
  List<PlanningRouteSchool> schools,
  String status,
  int editRevision,
  int routingRevision,
});

/// Recurring local civil-time configuration.
typedef PlanningSchedule = ({
  String id,
  String routeId,
  List<int> weekdays,
  String startsAt,
  String endsAt,
  bool endsNextDay,
  String timezone,
  String validFrom,
  String validUntil,
  int confirmationMinutes,
  String status,
  int editRevision,
});

/// Authoritative municipality metadata.
typedef PlanningCity = ({
  String cityIbgeCode,
  String cityName,
  String stateCode,
});

/// Published institution, including campus address and validated coordinates.
typedef PlanningSchool = ({
  String id,
  String name,
  String institutionType,
  String postalCode,
  String street,
  String streetNumber,
  String? addressComplement,
  String neighborhood,
  PlanningCity city,
  double latitude,
  double longitude,
});

/// An active operator; profile names may be absent.
typedef PlanningDriver = ({String userId, String? displayName});

/// Current owner's membership and effective operator status.
typedef OwnerOperator = ({String membershipId, bool isDriver});

/// Validated owner projection. Unknown properties are ignored for additive API changes.
class FleetPlanning {
  const FleetPlanning._({
    required this.vans,
    required this.routes,
    required this.schedules,
    required this.cities,
    required this.schools,
    required this.drivers,
    required this.ownerOperator,
    required this.reservations,
    required this.revisions,
    required this.enrollmentRevisions,
  });
  final List<PlanningVan> vans;
  final List<PlanningRoute> routes;
  final List<PlanningSchedule> schedules;
  final List<PlanningCity> cities;
  final List<PlanningSchool> schools;
  final List<PlanningDriver> drivers;
  final OwnerOperator ownerOperator;
  final List<Map<String, Object?>> reservations;
  final Map<String, int> revisions;
  final Map<String, int> enrollmentRevisions;

  /// Parses all existing collections and owner additions without synthetic defaults.
  factory FleetPlanning.fromJson(Map<String, dynamic> json) {
    final operator = planningObject(json['owner_operator'], 'owner_operator');
    return FleetPlanning._(
      vans: _rows(
        json,
        'vans',
        (r) => (
          id: planningId(r, 'id'),
          plate: planningString(r, 'plate'),
          model: planningString(r, 'model'),
          publicName: planningString(r, 'public_name'),
          capacity: planningInt(r, 'capacity', 1, 100),
          status: _status(r),
          editRevision: planningInt(r, 'edit_revision', 1),
        ),
      ),
      routes: _rows(json, 'routes', _route),
      schedules: _rows(json, 'schedules', _schedule),
      cities: _rows(json, 'service_cities', planningCity),
      schools: _rows(
        json,
        'service_schools',
        (r) => planningSchool(r, idKey: 'school_id'),
      ),
      drivers: _rows(
        json,
        'drivers',
        (r) => (
          userId: planningId(r, 'user_id'),
          displayName: planningNullableString(r, 'display_name'),
        ),
      ),
      ownerOperator: (
        membershipId: planningId(operator, 'membership_id'),
        isDriver: planningBool(operator, 'is_driver'),
      ),
      reservations: _rows(json, 'reservations', _reservation),
      revisions: _revisionMap(json, 'revisions', 'route_id'),
      enrollmentRevisions: _revisionMap(
        json,
        'enrollment_revisions',
        'enrollment_id',
      ),
    );
  }
}

/// Requires a JSON object; used by catalog and planning service boundaries.
Map<String, dynamic> planningObject(Object? value, String field) {
  if (value is! Map<String, dynamic>) {
    throw PlanningResponseFormatException(field);
  }
  return value;
}

/// Requires nonblank text without coercion.
String planningString(Map<String, dynamic> row, String key) {
  final value = row[key];
  if (value is! String || value.trim().isEmpty) {
    throw PlanningResponseFormatException(key);
  }
  return value;
}

/// Distinguishes an explicitly nullable field from a missing field.
String? planningNullableString(Map<String, dynamic> row, String key) {
  if (!row.containsKey(key)) throw PlanningResponseFormatException(key);
  return row[key] == null ? null : planningString(row, key);
}

final _uuid = RegExp(r'^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$');

/// Requires an API UUID, allowing PostgreSQL's full UUID value range.
String planningId(Map<String, dynamic> row, String key) {
  final value = planningString(row, key);
  if (!_uuid.hasMatch(value)) throw PlanningResponseFormatException(key);
  return value;
}

/// Requires an integer within a domain range, never a numeric string.
int planningInt(
  Map<String, dynamic> row,
  String key,
  int minimum, [
  int? maximum,
]) {
  final value = row[key];
  if (value is! int ||
      value < minimum ||
      (maximum != null && value > maximum)) {
    throw PlanningResponseFormatException(key);
  }
  return value;
}

/// Requires a JSON boolean.
bool planningBool(Map<String, dynamic> row, String key) {
  final value = row[key];
  if (value is! bool) throw PlanningResponseFormatException(key);
  return value;
}

String _choice(Map<String, dynamic> row, String key, List<String> values) {
  final value = planningString(row, key);
  if (!values.contains(value)) throw PlanningResponseFormatException(key);
  return value;
}

String _status(Map<String, dynamic> row) =>
    _choice(row, 'status', ['active', 'inactive']);
double _coordinate(Map<String, dynamic> row, String key, int limit) {
  final value = row[key];
  if (value is! num || !value.isFinite || value.abs() > limit) {
    throw PlanningResponseFormatException(key);
  }
  return value.toDouble();
}

/// Parses a confirmed endpoint; missing coordinates never become zero.
PlanningPoint planningPoint(Map<String, dynamic> row) => (
  latitude: _coordinate(row, 'latitude', 90),
  longitude: _coordinate(row, 'longitude', 180),
  label: planningString(row, 'label'),
);

/// Parses authoritative municipal lookup or fleet coverage metadata.
PlanningCity planningCity(Map<String, dynamic> row) {
  final code = planningString(row, 'city_ibge_code');
  final state = planningString(row, 'state_code');
  if (!RegExp(r'^35\d{5}$').hasMatch(code) || state != 'SP') {
    throw const PlanningResponseFormatException('city');
  }
  return (
    cityIbgeCode: code,
    cityName: planningString(row, 'city_name'),
    stateCode: state,
  );
}

/// Parses the existing catalog search shape or owner coverage shape.
PlanningSchool planningSchool(
  Map<String, dynamic> row, {
  String idKey = 'id',
}) => (
  id: planningId(row, idKey),
  name: planningString(row, 'name'),
  institutionType: _choice(row, 'institution_type', [
    'school',
    'higher_education',
  ]),
  postalCode: planningString(row, 'postal_code'),
  street: planningString(row, 'street'),
  streetNumber: planningString(row, 'street_number'),
  addressComplement: planningNullableString(row, 'address_complement'),
  neighborhood: planningString(row, 'neighborhood'),
  city: planningCity(row),
  latitude: _coordinate(row, 'latitude', 90),
  longitude: _coordinate(row, 'longitude', 180),
);
List<T> _rows<T>(
  Map<String, dynamic> row,
  String key,
  T Function(Map<String, dynamic>) parse,
) {
  final values = row[key];
  if (values is! List) throw PlanningResponseFormatException(key);
  return List.unmodifiable(
    values.map((value) => parse(planningObject(value, key))),
  );
}

PlanningRoute _route(Map<String, dynamic> row) {
  final pair = planningNullableString(row, 'paired_route_id');
  if (pair != null) planningId(row, 'paired_route_id');
  final schools = _rows(
    row,
    'schools',
    (r) => (
      schoolId: planningId(r, 'school_id'),
      position: planningInt(r, 'position', 1),
    ),
  );
  if (schools.map((s) => s.schoolId).toSet().length != schools.length) {
    throw const PlanningResponseFormatException('schools');
  }
  for (var i = 1; i < schools.length; i++) {
    if (schools[i].position <= schools[i - 1].position) {
      throw const PlanningResponseFormatException('school order');
    }
  }
  planningString(row, 'origin_label');
  planningString(row, 'destination_label');
  return (
    id: planningId(row, 'id'),
    name: planningString(row, 'name'),
    direction: _choice(row, 'direction', ['going', 'return']),
    shift: _choice(row, 'shift', [
      'morning',
      'afternoon',
      'evening',
      'full_time',
    ]),
    pairedRouteId: pair,
    vanId: planningId(row, 'van_id'),
    driverUserId: planningId(row, 'driver_user_id'),
    proximityMinutes: planningInt(row, 'proximity_minutes', 1, 60),
    origin: planningPoint(planningObject(row['origin'], 'origin')),
    destination: planningPoint(
      planningObject(row['destination'], 'destination'),
    ),
    schools: schools,
    status: _status(row),
    editRevision: planningInt(row, 'edit_revision', 1),
    routingRevision: planningInt(row, 'routing_revision', 1),
  );
}

/// Validates a civil date without accepting DateTime's overflowing dates.
String planningDate(Map<String, dynamic> row, String key) {
  final value = planningString(row, key);
  final parsed = DateTime.tryParse(value);
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value) ||
      parsed == null ||
      parsed.toIso8601String().substring(0, 10) != value) {
    throw PlanningResponseFormatException(key);
  }
  return value;
}

String _time(Map<String, dynamic> row, String key) {
  final value = planningString(row, key);
  if (!RegExp(
    r'^([01]\d|2[0-3]):[0-5]\d(?::[0-5]\d(?:\.\d{1,6})?)?$',
  ).hasMatch(value)) {
    throw PlanningResponseFormatException(key);
  }
  return value;
}

PlanningSchedule _schedule(Map<String, dynamic> row) {
  final days = row['weekdays'];
  if (days is! List ||
      days.isEmpty ||
      days.any((d) => d is! int || d < 1 || d > 7) ||
      days.toSet().length != days.length) {
    throw const PlanningResponseFormatException('weekdays');
  }
  final from = planningDate(row, 'valid_from'),
      until = planningDate(row, 'valid_until');
  if (from.compareTo(until) > 0) {
    throw const PlanningResponseFormatException('valid_until');
  }
  return (
    id: planningId(row, 'id'),
    routeId: planningId(row, 'route_id'),
    weekdays: List<int>.unmodifiable(days),
    startsAt: _time(row, 'starts_at'),
    endsAt: _time(row, 'ends_at'),
    endsNextDay: planningBool(row, 'ends_next_day'),
    timezone: planningString(row, 'timezone'),
    validFrom: from,
    validUntil: until,
    confirmationMinutes: planningInt(row, 'confirmation_minutes', 0, 1440),
    status: _status(row),
    editRevision: planningInt(row, 'edit_revision', 1),
  );
}

Map<String, int> _revisionMap(
  Map<String, dynamic> row,
  String key,
  String idKey,
) {
  final entries = _rows(
    row,
    key,
    (r) => (
      id: planningId(r, idKey),
      revision: planningInt(r, 'routing_revision', 1),
    ),
  );
  final result = {for (final entry in entries) entry.id: entry.revision};
  if (result.length != entries.length) {
    throw PlanningResponseFormatException(key);
  }
  return Map.unmodifiable(result);
}

Map<String, Object?> _reservation(Map<String, dynamic> row) {
  final result = <String, Object?>{};
  for (final key in [
    'id',
    'enrollment_id',
    'student_id',
    'route_student_schedule_id',
    'route_id',
    'schedule_id',
    'van_id',
  ]) {
    result[key] = planningId(row, key);
  }
  result['weekday'] = planningInt(row, 'weekday', 1, 7);
  result['direction'] = _choice(row, 'direction', ['going', 'return']);
  result['status'] = _choice(row, 'status', ['active', 'cancelled']);
  result['valid_from'] = planningDate(row, 'valid_from');
  result['valid_until'] = planningDate(row, 'valid_until');
  return Map.unmodifiable(result);
}
