import 'fleet_planning.dart';

/// Immutable van submission; retries retain ID, payload and expected revision.
class VanPlanningCommand {
  const VanPlanningCommand({
    required this.fleetId,
    required this.commandId,
    required this.plate,
    required this.model,
    required this.publicName,
    required this.capacity,
    this.id,
    this.expectedRevision,
  });
  final String fleetId, commandId, plate, model, publicName;
  final String? id;
  final int capacity;
  final int? expectedRevision;

  /// Exact named parameters select the revision-aware PostgREST overload.
  Map<String, Object?> toRpcParams() => {
    'p_fleet_id': fleetId,
    'p_van_id': id,
    'p_plate': plate,
    'p_model': model,
    'p_public_name': publicName,
    'p_capacity': capacity,
    'p_command_id': commandId,
    'p_expected_revision': expectedRevision,
  };
}

/// Immutable route configuration, including explicit points and ordered schools.
class RoutePlanningCommand {
  RoutePlanningCommand({
    required this.fleetId,
    required this.commandId,
    required this.name,
    required this.direction,
    required this.shift,
    required this.vanId,
    required this.driverUserId,
    required this.origin,
    required this.destination,
    required List<String> schoolIds,
    required this.proximityMinutes,
    this.pairedRouteId,
    this.id,
    this.expectedRevision,
  }) : schoolIds = List.unmodifiable(schoolIds);
  final String fleetId, commandId, name, direction, shift, vanId, driverUserId;
  final String? id, pairedRouteId;
  final int? expectedRevision;
  final int proximityMinutes;
  final PlanningPoint origin, destination;
  final List<String> schoolIds;

  /// Preserves pairing and institution order; the server validates eligibility.
  Map<String, Object?> toRpcParams() => {
    'p_fleet_id': fleetId,
    'p_route_id': id,
    'p_command_id': commandId,
    'p_expected_revision': expectedRevision,
    'p_config': {
      'name': name,
      'direction': direction,
      'shift': shift,
      'van_id': vanId,
      'driver_user_id': driverUserId,
      'paired_route_id': pairedRouteId,
      'proximity_minutes': proximityMinutes,
      'origin': {
        'latitude': origin.latitude,
        'longitude': origin.longitude,
        'label': origin.label,
      },
      'destination': {
        'latitude': destination.latitude,
        'longitude': destination.longitude,
        'label': destination.label,
      },
      'schools': [
        for (var i = 0; i < schoolIds.length; i++)
          {'school_id': schoolIds[i], 'position': i + 1},
      ],
    },
  };
}

/// Immutable schedule input using civil dates and explicit overnight semantics.
class SchedulePlanningCommand {
  SchedulePlanningCommand({
    required this.routeId,
    required this.commandId,
    required List<int> weekdays,
    required this.startsAt,
    required this.endsAt,
    required this.endsNextDay,
    required this.timezone,
    required this.validFrom,
    required this.validUntil,
    required this.confirmationMinutes,
    this.id,
    this.expectedRevision,
  }) : weekdays = List.unmodifiable(weekdays);
  final String routeId,
      commandId,
      startsAt,
      endsAt,
      timezone,
      validFrom,
      validUntil;
  final List<int> weekdays;
  final bool endsNextDay;
  final String? id;
  final int confirmationMinutes;
  final int? expectedRevision;

  /// Exact schedule parameters include explicit creation nulls.
  Map<String, Object?> toRpcParams() => {
    'p_route_id': routeId,
    'p_schedule_id': id,
    'p_command_id': commandId,
    'p_expected_revision': expectedRevision,
    'p_schedule': {
      'weekdays': weekdays,
      'starts_at': startsAt,
      'ends_at': endsAt,
      'ends_next_day': endsNextDay,
      'timezone': timezone,
      'valid_from': validFrom,
      'valid_until': validUntil,
      'confirmation_minutes': confirmationMinutes,
    },
  };
}
