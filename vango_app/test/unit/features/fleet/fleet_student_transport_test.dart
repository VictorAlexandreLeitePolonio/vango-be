import 'package:flutter_test/flutter_test.dart';
import 'package:vango_app/features/fleet/models/fleet_planning.dart';
import 'package:vango_app/features/fleet/models/fleet_student_transport.dart';
import 'fleet_planning_test.dart';

const enrollmentId = '30fb15de-8023-41ee-a1dc-16877cf93e35';
const schoolId = '65000000-0000-0000-0000-000000000001';
const goingSchedule = '50f207a3-848d-4610-998d-850453c2025d';
const returnSchedule = '9310e103-7522-4de6-9d3f-8db2a09b932f';
const goingRoute = '00354135-5eae-421f-8ac2-0aac09931f8d';

/// Builds a reservation row in the exact owner projection shape.
Map<String, Object?> reservationRow({
  required int weekday,
  required String direction,
  required String scheduleId,
  required String routeId,
  String enrollment = enrollmentId,
  String status = 'active',
  String validFrom = '2026-10-06',
  String validUntil = '2026-12-25',
}) {
  final suffix = '$weekday${direction == 'going' ? 1 : 2}';
  return {
    'id': '70000000-0000-4000-8000-0000000000$suffix',
    'enrollment_id': enrollment,
    'student_id': '72000000-0000-4000-8000-000000000001',
    'route_student_schedule_id': '71000000-0000-4000-8000-0000000000$suffix',
    'route_id': routeId,
    'schedule_id': scheduleId,
    'van_id': '8f49779b-2360-4b69-8b22-af2e579eccfe',
    'weekday': weekday,
    'direction': direction,
    'valid_from': validFrom,
    'valid_until': validUntil,
    'status': status,
  };
}

FleetPlanning planningWith(void Function(Map<String, dynamic> json) edit) {
  final json = planningFixture();
  edit(json);
  return FleetPlanning.fromJson(json);
}

List<String> optionIds(
  FleetPlanning planning, {
  String shift = 'morning',
  int weekday = 1,
  String direction = 'going',
  String effectiveOn = '2026-10-06',
  String school = schoolId,
}) => compatibleTransportOptions(
  planning,
  schoolId: school,
  shift: shift,
  slot: (weekday: weekday, direction: direction),
  effectiveOn: effectiveOn,
).map((option) => option.schedule.id).toList();

void main() {
  group('compatibleTransportOptions', () {
    final planning = FleetPlanning.fromJson(planningFixture());

    test(
      'returns the schedule whose route matches school, shift and direction',
      () {
        expect(optionIds(planning), [goingSchedule]);
        expect(optionIds(planning, direction: 'return'), [returnSchedule]);
      },
    );

    test('excludes weekdays outside the schedule', () {
      expect(optionIds(planning, weekday: 6), isEmpty);
    });

    test('excludes another shift or school', () {
      expect(optionIds(planning, shift: 'afternoon'), isEmpty);
      expect(
        optionIds(planning, school: '65000000-0000-0000-0000-000000000099'),
        isEmpty,
      );
    });

    test('respects inclusive schedule validity bounds', () {
      expect(optionIds(planning, effectiveOn: '2026-09-27'), [goingSchedule]);
      expect(optionIds(planning, effectiveOn: '2026-12-25'), [goingSchedule]);
      expect(optionIds(planning, effectiveOn: '2026-09-26'), isEmpty);
      expect(optionIds(planning, effectiveOn: '2026-12-26'), isEmpty);
    });

    test('excludes inactive schedules and inactive routes', () {
      expect(
        optionIds(
          planningWith(
            (j) => (j['schedules'] as List).first['status'] = 'inactive',
          ),
        ),
        isEmpty,
      );
      expect(
        optionIds(
          planningWith(
            (j) => (j['routes'] as List).first['status'] = 'inactive',
          ),
        ),
        isEmpty,
      );
    });
  });

  group('saved plan projection', () {
    final planning = planningWith(
      (j) => j['reservations'] = [
        reservationRow(
          weekday: 2,
          direction: 'going',
          scheduleId: goingSchedule,
          routeId: goingRoute,
        ),
        reservationRow(
          weekday: 1,
          direction: 'going',
          scheduleId: goingSchedule,
          routeId: goingRoute,
          validFrom: '2026-09-28',
          validUntil: '2026-10-05',
        ),
        reservationRow(
          weekday: 3,
          direction: 'going',
          scheduleId: goingSchedule,
          routeId: goingRoute,
          status: 'cancelled',
        ),
        reservationRow(
          weekday: 4,
          direction: 'going',
          scheduleId: goingSchedule,
          routeId: goingRoute,
          enrollment: 'ac28fa78-5a0b-429f-872e-35053a59dcd3',
        ),
      ],
    );

    test(
      'allocationsInEffect keeps only active rows of the enrollment covering the date',
      () {
        expect(allocationsInEffect(planning, enrollmentId, '2026-10-06'), {
          (weekday: 2, direction: 'going'): goingSchedule,
        });
        expect(allocationsInEffect(planning, enrollmentId, '2026-10-05'), {
          (weekday: 1, direction: 'going'): goingSchedule,
        });
      },
    );

    test(
      'savedStudentReservations hides ended, cancelled and foreign rows, ordered by start',
      () {
        final rows = savedStudentReservations(
          planning,
          enrollmentId,
          '2026-10-05',
        );
        expect(rows.map((r) => r['weekday']), [1, 2]);
        expect(
          savedStudentReservations(
            planning,
            enrollmentId,
            '2026-10-06',
          ).map((r) => r['weekday']),
          [2],
        );
      },
    );
  });

  group('StudentTransportDraft', () {
    StudentTransportDraft draft(Map<TransportSlot, String> allocations) =>
        StudentTransportDraft(
          enrollmentId: enrollmentId,
          schoolId: schoolId,
          allocations: allocations,
          effectiveOn: '2026-10-06',
          expectedRoutingRevision: 1,
        );

    test(
      'sends exact RPC keys with allocations sorted by weekday then direction',
      () {
        final params = draft({
          (weekday: 2, direction: 'going'): goingSchedule,
          (weekday: 1, direction: 'return'): returnSchedule,
          (weekday: 1, direction: 'going'): goingSchedule,
        }).toRpcParams('cmd');
        expect(params, {
          'p_enrollment_id': enrollmentId,
          'p_school_id': schoolId,
          'p_allocations': [
            {'schedule_id': goingSchedule, 'weekday': 1, 'direction': 'going'},
            {
              'schedule_id': returnSchedule,
              'weekday': 1,
              'direction': 'return',
            },
            {'schedule_id': goingSchedule, 'weekday': 2, 'direction': 'going'},
          ],
          'p_effective_on': '2026-10-06',
          'p_command_id': 'cmd',
          'p_expected_routing_revision': 1,
        });
      },
    );

    test('payloadKey ignores insertion order and changes with any input', () {
      final a = draft({
        (weekday: 1, direction: 'going'): goingSchedule,
        (weekday: 1, direction: 'return'): returnSchedule,
      });
      final b = draft({
        (weekday: 1, direction: 'return'): returnSchedule,
        (weekday: 1, direction: 'going'): goingSchedule,
      });
      final c = draft({(weekday: 1, direction: 'going'): goingSchedule});
      expect(a.payloadKey, b.payloadKey);
      expect(a.payloadKey, isNot(c.payloadKey));
    });

    test('allocations are a defensive copy', () {
      final source = {(weekday: 1, direction: 'going'): goingSchedule};
      final value = draft(source);
      source.clear();
      expect(value.allocations, hasLength(1));
    });
  });

  test('civilDate pads to an ISO civil date', () {
    expect(civilDate(DateTime(2026, 1, 5)), '2026-01-05');
  });

  test('transportSlots lists 14 pairs, going before return per weekday', () {
    expect(transportSlots, hasLength(14));
    expect(transportSlots.take(2), [
      (weekday: 1, direction: 'going'),
      (weekday: 1, direction: 'return'),
    ]);
  });
}
