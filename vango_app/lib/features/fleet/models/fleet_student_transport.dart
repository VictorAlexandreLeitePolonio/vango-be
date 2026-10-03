import 'dart:convert';
import 'fleet_planning.dart';

/// One ISO weekday (1 = Monday) and direction of the weekly transport plan.
typedef TransportSlot = ({int weekday, String direction});

/// A persisted schedule together with the route that owns it.
typedef TransportOption = ({PlanningSchedule schedule, PlanningRoute route});

/// Every weekday/direction pair in display order.
// Enumerated literally because a `for` element is not a constant expression.
const List<TransportSlot> transportSlots = [
  (weekday: 1, direction: 'going'),
  (weekday: 1, direction: 'return'),
  (weekday: 2, direction: 'going'),
  (weekday: 2, direction: 'return'),
  (weekday: 3, direction: 'going'),
  (weekday: 3, direction: 'return'),
  (weekday: 4, direction: 'going'),
  (weekday: 4, direction: 'return'),
  (weekday: 5, direction: 'going'),
  (weekday: 5, direction: 'return'),
  (weekday: 6, direction: 'going'),
  (weekday: 6, direction: 'return'),
  (weekday: 7, direction: 'going'),
  (weekday: 7, direction: 'return'),
];

/// Formats a local calendar day as the API civil date `YYYY-MM-DD`.
String civilDate(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

/// Display-only mirror of `private.validate_transport_allocations`.
/// Capacity, conflicts, driver status and date openness stay backend decisions.
List<TransportOption> compatibleTransportOptions(
  FleetPlanning planning, {
  required String schoolId,
  required String shift,
  required TransportSlot slot,
  required String effectiveOn,
}) {
  final routes = {for (final route in planning.routes) route.id: route};
  final options = <TransportOption>[
    for (final schedule in planning.schedules)
      if (routes[schedule.routeId] case final route?)
        if (schedule.status == 'active' &&
            schedule.weekdays.contains(slot.weekday) &&
            schedule.validFrom.compareTo(effectiveOn) <= 0 &&
            schedule.validUntil.compareTo(effectiveOn) >= 0 &&
            route.status == 'active' &&
            route.shift == shift &&
            route.direction == slot.direction &&
            route.schools.any((school) => school.schoolId == schoolId))
          (schedule: schedule, route: route),
  ];
  options.sort((a, b) => a.schedule.startsAt.compareTo(b.schedule.startsAt));
  return options;
}

bool _activeFor(Map<String, Object?> row, String enrollmentId) =>
    row['enrollment_id'] == enrollmentId && row['status'] == 'active';

/// Slot selections persisted for [enrollmentId] that cover [date].
Map<TransportSlot, String> allocationsInEffect(
  FleetPlanning planning,
  String enrollmentId,
  String date,
) => {
  for (final row in planning.reservations)
    if (_activeFor(row, enrollmentId) &&
        (row['valid_from']! as String).compareTo(date) <= 0 &&
        (row['valid_until']! as String).compareTo(date) >= 0)
      (weekday: row['weekday']! as int, direction: row['direction']! as String):
          row['schedule_id']! as String,
};

/// Active reservations of [enrollmentId] not ended before [today], by start date.
List<Map<String, Object?>> savedStudentReservations(
  FleetPlanning planning,
  String enrollmentId,
  String today,
) {
  final rows = [
    for (final row in planning.reservations)
      if (_activeFor(row, enrollmentId) &&
          (row['valid_until']! as String).compareTo(today) >= 0)
        row,
  ];
  rows.sort((a, b) {
    final byStart = (a['valid_from']! as String).compareTo(
      b['valid_from']! as String,
    );
    if (byStart != 0) return byStart;
    final byDay = (a['weekday']! as int).compareTo(b['weekday']! as int);
    if (byDay != 0) return byDay;
    return (a['direction']! as String).compareTo(b['direction']! as String);
  });
  return rows;
}

/// Owner allocation input without identity; equal payloads must reuse one command id.
class StudentTransportDraft {
  StudentTransportDraft({
    required this.enrollmentId,
    required this.schoolId,
    required Map<TransportSlot, String> allocations,
    required this.effectiveOn,
    required this.expectedRoutingRevision,
  }) : allocations = Map.unmodifiable(allocations);

  final String enrollmentId, schoolId, effectiveOn;
  final Map<TransportSlot, String> allocations;
  final int expectedRoutingRevision;

  /// Exact `assign_fleet_student_transport` parameters; items are canonically ordered.
  Map<String, Object?> toRpcParams(String commandId) {
    final entries = allocations.entries.toList()
      ..sort((a, b) {
        final byDay = a.key.weekday.compareTo(b.key.weekday);
        return byDay != 0 ? byDay : a.key.direction.compareTo(b.key.direction);
      });
    return {
      'p_enrollment_id': enrollmentId,
      'p_school_id': schoolId,
      'p_allocations': [
        for (final entry in entries)
          {
            'schedule_id': entry.value,
            'weekday': entry.key.weekday,
            'direction': entry.key.direction,
          },
      ],
      'p_effective_on': effectiveOn,
      'p_command_id': commandId,
      'p_expected_routing_revision': expectedRoutingRevision,
    };
  }

  /// Payload identity excluding the command id, used to decide id reuse on retry.
  String get payloadKey => jsonEncode(toRpcParams(''));
}
