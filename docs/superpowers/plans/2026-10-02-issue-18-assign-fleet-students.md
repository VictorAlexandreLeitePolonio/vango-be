# Issue 18 Assign Fleet Students to Route Schedules Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a fleet owner place a directly enrolled (owner-registered) student into the persisted weekly transport plan from Flutter, through the existing `assign_fleet_student_transport` RPC, with the saved plan always rendered from the backend projection.

**Architecture:** No backend change. #16 already ships `public.assign_fleet_student_transport` (idempotent, revision-guarded, capacity/conflict-checked) and `public.get_fleet_planning` already projects routes (with schools/shift/direction), schedules, reservations and `enrollment_revisions`. Flutter adds: (1) the enrollment/school/shift fields that `list_fleet_students` already returns but the app discards, (2) one pure model file that filters compatible schedules for display and builds the command payload, (3) one service method, (4) one screen opened from each student card in the owner dashboard.

**Tech Stack:** Flutter/Dart (SDK `^3.11.3`), Material, `supabase_flutter` RPC, `flutter_test` with `http/testing.dart` `MockClient`. No new dependency.

**Spec:** GitHub issue [VictorAlexandreLeitePolonio/vango-be#18](https://github.com/VictorAlexandreLeitePolonio/vango-be/issues/18) (parent PRD [#15](https://github.com/VictorAlexandreLeitePolonio/vango-be/issues/15)). Backend contract: `supabase/migrations/20260926193617_fleet_transport_commands.sql`, `supabase/migrations/20260926193138_fleet_transport_shared_validation.sql`, `supabase/migrations/20260926220353_fleet_planning_projection.sql`. Product decisions agreed with the owner of the repo are listed in "Decisions" below.

## Global Constraints

- Branch: `claude/task-18-assign-fleet-students` (created from `origin/codex/task-17-owner-fleet-planning` at `05018e7`). Do not rebase onto `dev-polonio`/`main` — they do not contain #9–#17.
- Strict TDD: RED → GREEN → Refactor per step. Run the failing test and record the failure before writing production code (AGENTS.md / CONTRIBUTING.md).
- English for code, identifiers, comments, test descriptions, commit messages. **pt-BR for every user-visible string** (labels, buttons, snackbars, errors).
- `flutter analyze` → `No issues found!`; `dart format --set-exit-if-changed lib test` clean; `flutter test --coverage` green; ≥ 80% coverage on `services/` and the new model file.
- Flutter never writes tables and never creates a marketplace/join request. Only RPC: `assign_fleet_student_transport`. Reads: `get_fleet_planning`, `list_fleet_students`.
- Backend is authoritative for capacity, conflicts, driver status and date openness. The Flutter compatibility filter is display-only.
- No partial or local success: a success message appears only after the RPC returns a receipt, and the saved plan shown is always re-read from `get_fleet_planning`.
- Stable command ids: the same unconfirmed payload is retried with the same `command_id`; any payload change gets a new id.
- Commits only with explicit authorization of the repo owner (CONTRIBUTING.md §"Do not commit or push without explicit authorization"). Commit steps below are checkpoints to run **once authorized**; Conventional Commits, English, ending with the attribution line required by the session.
- Flutter commands run inside `vango_app/`. Flutter was installed via `brew install --cask flutter`; run `flutter pub get` once if `.dart_tool/` is missing.

## Decisions (agreed in the planning conversation)

1. UI entry point: an icon button with tooltip **"Programar transporte"** on each student card of the owner dashboard opens a dedicated screen (the registration screen is not extended).
2. The school is **not selectable**: the RPC rejects any `p_school_id` different from the enrollment's school (`invalid_input`). The screen shows the enrollment school/shift read-only and blocks with a message if either is missing.
3. Effective date: **tomorrow is pre-filled as a suggestion**, the owner can pick any date from today up to one year ahead via `showDatePicker`. The backend decides whether the date is still open (`effective_date_conflict`).
4. Compatible schedules are filtered in Flutter for display only, mirroring `private.validate_transport_allocations`: schedule `active`, weekday ∈ `weekdays`, `valid_from ≤ effectiveOn ≤ valid_until`, route `active`, `route.shift == enrollment.shift`, `route.direction == slot.direction`, route serves the enrollment school.

## Backend contract cheat sheet (read-only, do not modify)

```sql
public.assign_fleet_student_transport(
  p_enrollment_id uuid, p_school_id uuid,
  p_allocations jsonb,          -- 1..14 items: {"schedule_id": uuid, "weekday": 1..7 (ISO, 1 = Monday), "direction": "going"|"return"}
  p_effective_on date,          -- 'YYYY-MM-DD'
  p_command_id uuid,
  p_expected_routing_revision bigint  -- from get_fleet_planning.enrollment_revisions
) returns table(command_id uuid, enrollment_id uuid, routing_revision bigint, effective_on date)
```

- Exactly those three keys per allocation item; extra keys → `invalid_input`. Each (weekday, direction) at most once.
- It **replaces** the enrollment's plan from `p_effective_on` (earlier rows are cut to `effective_on - 1`, later rows cancelled). Removing all allocations is not supported (min 1 item) — out of scope.
- Same `command_id` + same payload → returns the original receipt (idempotent replay). Same id + different payload → `idempotency_conflict`.
- Error codes (`PostgrestException.code`): `unauthenticated`, `email_unverified`, `not_found` (enrollment not in an owned fleet), `invalid_input` (bad payload, school mismatch, schedule not available/incompatible, driver inactive), `idempotency_conflict`, `revision_conflict` (enrollment plan changed since read), `invalid_transition` (enrollment not owner-registered/active), `effective_date_conflict` (date outside validity or no longer open), `capacity_exceeded`, `schedule_conflict` (student conflict), `allocation_failed` (unexpected 500, transaction rolled back).
- `list_fleet_students(p_fleet_id)` rows: `enrollment_id, student_id, student_type, full_name, postal_code, street, street_number, address_complement, neighborhood, city_name, state_code, school_id (nullable), school_name (nullable), shift (nullable: morning|afternoon|evening|full_time)`.
- `get_fleet_planning` reservation rows (owner view): `id, enrollment_id, student_id, route_student_schedule_id, route_id, schedule_id, van_id, weekday, direction, valid_from, valid_until, status (active|cancelled)`. Already parsed by `FleetPlanning.reservations` as `List<Map<String, Object?>>`.

## File map

| Deliverable | Files |
| --- | --- |
| Student projection keeps transport identity | Modify `vango_app/lib/features/fleet/services/fleet_service.dart` (typedef line 61, `getOwnerEnrolledStudents` ~line 288); tests `vango_app/test/unit/features/fleet/fleet_service_test.dart`, record literals in `vango_app/test/widget/features/fleet/fleet_owner_dashboard_screen_test.dart` and `vango_app/test/widget/features/fleet/owner_flow_reliability_test.dart` |
| Pure transport model | Create `vango_app/lib/features/fleet/models/fleet_student_transport.dart`; test `vango_app/test/unit/features/fleet/fleet_student_transport_test.dart` |
| RPC + error copy | Modify `vango_app/lib/features/fleet/services/fleet_planning_service.dart`, `vango_app/lib/features/fleet/services/fleet_planning_error_mapper.dart`; tests `vango_app/test/unit/features/fleet/fleet_planning_service_test.dart`, `vango_app/test/unit/features/fleet/fleet_planning_error_mapper_test.dart` |
| Screen | Create `vango_app/lib/features/fleet/screens/fleet_student_transport_screen.dart`; test `vango_app/test/widget/features/fleet/fleet_student_transport_screen_test.dart` |
| Dashboard entry | Modify `vango_app/lib/features/fleet/screens/fleet_owner_dashboard_screen.dart`; test `vango_app/test/widget/features/fleet/fleet_owner_dashboard_screen_test.dart` |

## Test fixture facts (from `vango_app/test/fixtures/fleet_planning.json`, loaded by `planningFixture()` in `test/unit/features/fleet/fleet_planning_test.dart`)

| Constant | Value |
| --- | --- |
| Enrollment with revision 1 | `30fb15de-8023-41ee-a1dc-16877cf93e35` |
| Served school | `65000000-0000-0000-0000-000000000001` ("Escola Ciclo 3") |
| Going route | `00354135-5eae-421f-8ac2-0aac09931f8d` "Ciclo 3 ida", morning, active |
| Return route | `2f2f287c-5314-4277-b480-9a0dfdce9864` "Ciclo 3 volta", morning, active |
| Going schedule | `50f207a3-848d-4610-998d-850453c2025d`, weekdays 1–5, 08:00, valid 2026-09-27..2026-12-25 |
| Return schedule | `9310e103-7522-4de6-9d3f-8db2a09b932f`, weekdays 1–5, 16:00, same validity |
| Van | `8f49779b-2360-4b69-8b22-af2e579eccfe` |
| Reservations | `[]` |

Tests pin "today" to **Monday 2026-10-05**, so the suggested effective date is **2026-10-06**.

---

### Task 1: Keep enrollment, school and shift in the owner student projection

**Files:**
- Modify: `vango_app/lib/features/fleet/services/fleet_service.dart:61` and `getOwnerEnrolledStudents` (~lines 288–311)
- Test: `vango_app/test/unit/features/fleet/fleet_service_test.dart` (test `'owner student list uses its fleet-scoped RPC projection'`, ~line 252)
- Modify record literals: `vango_app/test/widget/features/fleet/fleet_owner_dashboard_screen_test.dart` (~lines 129–134, 250–255, 258) and `vango_app/test/widget/features/fleet/owner_flow_reliability_test.dart` (~lines 362–366)

**Interfaces:**
- Produces:
  ```dart
  typedef OwnerEnrolledStudent = ({
    String id,
    String enrollmentId,
    String fullName,
    String address,
    String? schoolId,
    String? schoolName,
    String? shift,
  });
  ```

- [ ] **Step 1: Write the failing test** — replace the body of `'owner student list uses its fleet-scoped RPC projection'` in `fleet_service_test.dart`:

```dart
  test('owner student list uses its fleet-scoped RPC projection', () async {
    final client = await _authenticatedClient((request) async {
      expect(request.url.path, endsWith('/rpc/list_fleet_students'));
      expect(jsonDecode(request.body), {'p_fleet_id': 'fleet-a'});
      return http.Response(
        jsonEncode([
          {
            'enrollment_id': 'enrollment-a',
            'student_id': 'student-a',
            'full_name': 'Aluno Teste',
            'street': 'Rua',
            'street_number': '1',
            'neighborhood': 'Centro',
            'city_name': 'Cidade',
            'school_id': 'school-a',
            'school_name': 'Escola',
            'shift': 'morning',
          },
          {
            'enrollment_id': 'enrollment-b',
            'student_id': 'student-b',
            'full_name': 'Sem Escola',
            'street': 'Rua',
            'street_number': '2',
            'neighborhood': 'Centro',
            'city_name': 'Cidade',
            'school_id': null,
            'school_name': null,
            'shift': null,
          },
        ]),
        200,
        headers: {'content-type': 'application/json'},
        request: request,
      );
    });
    addTearDown(client.dispose);

    final students = await FleetService(
      client: client,
    ).getOwnerEnrolledStudents('fleet-a');
    expect(students.first.fullName, 'Aluno Teste');
    expect(students.first.address, 'Rua, 1 - Centro, Cidade');
    expect(students.first.enrollmentId, 'enrollment-a');
    expect(students.first.schoolId, 'school-a');
    expect(students.first.schoolName, 'Escola');
    expect(students.first.shift, 'morning');
    expect(students.last.schoolId, isNull);
    expect(students.last.shift, isNull);
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd vango_app && flutter test test/unit/features/fleet/fleet_service_test.dart --plain-name "owner student list uses its fleet-scoped RPC projection"`
Expected: compilation FAIL — `The getter 'enrollmentId' isn't defined for the type '({String address, String fullName, String id})'`.

- [ ] **Step 3: Minimal implementation** in `fleet_service.dart`:

```dart
/// Owner-visible enrolled student, including the enrollment that receives transport.
typedef OwnerEnrolledStudent = ({
  String id,
  String enrollmentId,
  String fullName,
  String address,
  String? schoolId,
  String? schoolName,
  String? shift,
});
```

and in `getOwnerEnrolledStudents` replace the returned record:

```dart
      return (
        id: row['student_id'] as String,
        enrollmentId: row['enrollment_id'] as String,
        fullName: row['full_name'] as String,
        address: '$street, $number - $neighborhood, $city',
        schoolId: row['school_id'] as String?,
        schoolName: row['school_name'] as String?,
        shift: row['shift'] as String?,
      );
```

- [ ] **Step 4: Fix the existing record literals** so the suite compiles. Each literal gains the four new fields. Example (`fleet_owner_dashboard_screen_test.dart` ~line 129):

```dart
      fleet.students = [
        (
          id: 'server-student',
          enrollmentId: 'server-enrollment',
          fullName: 'Nome canônico do servidor',
          address: 'Rua canônica',
          schoolId: null,
          schoolName: null,
          shift: null,
        ),
      ];
```

Apply the same shape to: `(id: 'new', ...)` → `enrollmentId: 'new-enrollment'`; `(id: 'old', ...)` → `enrollmentId: 'old-enrollment'`; `owner_flow_reliability_test.dart` `(id: 'canonical-student', ...)` → `enrollmentId: 'canonical-enrollment'`. Find any remaining ones with:
`grep -rn "fullName:" vango_app/test | grep -v enrollmentId`

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd vango_app && flutter test test/unit/features/fleet test/widget/features/fleet`
Expected: all PASS.

- [ ] **Step 6: Commit (once authorized)**

```bash
git add vango_app/lib/features/fleet/services/fleet_service.dart vango_app/test/unit/features/fleet/fleet_service_test.dart vango_app/test/widget/features/fleet/fleet_owner_dashboard_screen_test.dart vango_app/test/widget/features/fleet/owner_flow_reliability_test.dart
git commit -m "feat(fleet): keep enrollment school and shift in owner student list"
```

---

### Task 2: Pure transport model (compatible schedules, saved plan, command payload)

**Files:**
- Create: `vango_app/lib/features/fleet/models/fleet_student_transport.dart`
- Test: `vango_app/test/unit/features/fleet/fleet_student_transport_test.dart`

**Interfaces:**
- Consumes: `FleetPlanning`, `PlanningSchedule`, `PlanningRoute` from `models/fleet_planning.dart`.
- Produces (exact names used by Tasks 3–5):
  ```dart
  typedef TransportSlot = ({int weekday, String direction});
  typedef TransportOption = ({PlanningSchedule schedule, PlanningRoute route});
  const List<TransportSlot> transportSlots;
  String civilDate(DateTime date);                // 'YYYY-MM-DD'
  List<TransportOption> compatibleTransportOptions(FleetPlanning planning, {required String schoolId, required String shift, required TransportSlot slot, required String effectiveOn});
  Map<TransportSlot, String> allocationsInEffect(FleetPlanning planning, String enrollmentId, String date); // slot -> schedule id
  List<Map<String, Object?>> savedStudentReservations(FleetPlanning planning, String enrollmentId, String today);
  class StudentTransportDraft { enrollmentId, schoolId, allocations, effectiveOn, expectedRoutingRevision; Map<String, Object?> toRpcParams(String commandId); String get payloadKey; }
  ```

- [ ] **Step 1: Write the failing tests** — create `fleet_student_transport_test.dart`:

```dart
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

    test('returns the schedule whose route matches school, shift and direction', () {
      expect(optionIds(planning), [goingSchedule]);
      expect(optionIds(planning, direction: 'return'), [returnSchedule]);
    });

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
        optionIds(planningWith((j) => (j['schedules'] as List).first['status'] = 'inactive')),
        isEmpty,
      );
      expect(
        optionIds(planningWith((j) => (j['routes'] as List).first['status'] = 'inactive')),
        isEmpty,
      );
    });
  });

  group('saved plan projection', () {
    final planning = planningWith(
      (j) => j['reservations'] = [
        reservationRow(weekday: 2, direction: 'going', scheduleId: goingSchedule, routeId: goingRoute),
        reservationRow(
          weekday: 1,
          direction: 'going',
          scheduleId: goingSchedule,
          routeId: goingRoute,
          validFrom: '2026-09-28',
          validUntil: '2026-10-05',
        ),
        reservationRow(weekday: 3, direction: 'going', scheduleId: goingSchedule, routeId: goingRoute, status: 'cancelled'),
        reservationRow(
          weekday: 4,
          direction: 'going',
          scheduleId: goingSchedule,
          routeId: goingRoute,
          enrollment: 'ac28fa78-5a0b-429f-872e-35053a59dcd3',
        ),
      ],
    );

    test('allocationsInEffect keeps only active rows of the enrollment covering the date', () {
      expect(allocationsInEffect(planning, enrollmentId, '2026-10-06'), {
        (weekday: 2, direction: 'going'): goingSchedule,
      });
      expect(allocationsInEffect(planning, enrollmentId, '2026-10-05'), {
        (weekday: 1, direction: 'going'): goingSchedule,
      });
    });

    test('savedStudentReservations hides ended, cancelled and foreign rows, ordered by start', () {
      final rows = savedStudentReservations(planning, enrollmentId, '2026-10-05');
      expect(rows.map((r) => r['weekday']), [1, 2]);
      expect(savedStudentReservations(planning, enrollmentId, '2026-10-06').map((r) => r['weekday']), [2]);
    });
  });

  group('StudentTransportDraft', () {
    StudentTransportDraft draft(Map<TransportSlot, String> allocations) => StudentTransportDraft(
      enrollmentId: enrollmentId,
      schoolId: schoolId,
      allocations: allocations,
      effectiveOn: '2026-10-06',
      expectedRoutingRevision: 1,
    );

    test('sends exact RPC keys with allocations sorted by weekday then direction', () {
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
          {'schedule_id': returnSchedule, 'weekday': 1, 'direction': 'return'},
          {'schedule_id': goingSchedule, 'weekday': 2, 'direction': 'going'},
        ],
        'p_effective_on': '2026-10-06',
        'p_command_id': 'cmd',
        'p_expected_routing_revision': 1,
      });
    });

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
```

- [ ] **Step 2: Run to verify RED**

Run: `cd vango_app && flutter test test/unit/features/fleet/fleet_student_transport_test.dart`
Expected: compilation FAIL — `Target of URI doesn't exist: 'package:vango_app/features/fleet/models/fleet_student_transport.dart'`.

- [ ] **Step 3: Minimal implementation** — create `fleet_student_transport.dart`:

```dart
import 'dart:convert';
import 'fleet_planning.dart';

/// One ISO weekday (1 = Monday) and direction of the weekly transport plan.
typedef TransportSlot = ({int weekday, String direction});

/// A persisted schedule together with the route that owns it.
typedef TransportOption = ({PlanningSchedule schedule, PlanningRoute route});

/// Every weekday/direction pair in display order.
const List<TransportSlot> transportSlots = [
  for (var weekday = 1; weekday <= 7; weekday++) ...[
    (weekday: weekday, direction: 'going'),
    (weekday: weekday, direction: 'return'),
  ],
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
    final byStart = (a['valid_from']! as String).compareTo(b['valid_from']! as String);
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
```

- [ ] **Step 4: Run to verify GREEN**

Run: `cd vango_app && flutter test test/unit/features/fleet/fleet_student_transport_test.dart && dart format lib/features/fleet/models/fleet_student_transport.dart test/unit/features/fleet/fleet_student_transport_test.dart`
Expected: all PASS; format rewrites long lines in the test file (that is expected — the snippets above are not pre-formatted).

- [ ] **Step 5: Commit (once authorized)**

```bash
git add vango_app/lib/features/fleet/models/fleet_student_transport.dart vango_app/test/unit/features/fleet/fleet_student_transport_test.dart
git commit -m "feat(fleet): model compatible schedules and student transport payload"
```

---

### Task 3: Service method and error copy for direct allocation

**Files:**
- Modify: `vango_app/lib/features/fleet/services/fleet_planning_service.dart`
- Modify: `vango_app/lib/features/fleet/services/fleet_planning_error_mapper.dart`
- Test: `vango_app/test/unit/features/fleet/fleet_planning_service_test.dart`, `vango_app/test/unit/features/fleet/fleet_planning_error_mapper_test.dart`

**Interfaces:**
- Consumes: `StudentTransportDraft` (Task 2), existing helpers `planningObject`, `planningId`, `planningInt`, `PlanningResponseFormatException` from `fleet_planning.dart`.
- Produces:
  ```dart
  // FleetPlanningService
  Future<int> assignStudentTransport(StudentTransportDraft draft, String commandId); // returns new routing_revision
  // PlanningErrorMapper: 'effective_date_conflict' => PlanningFailure.rejected
  ```

- [ ] **Step 1: Write the failing service tests** — append inside `main()` of `fleet_planning_service_test.dart` (it already defines `testId` and `planningClient`; add the import `package:vango_app/features/fleet/models/fleet_student_transport.dart`):

```dart
  group('assignStudentTransport', () {
    const enrollment = '30fb15de-8023-41ee-a1dc-16877cf93e35';
    const school = '65000000-0000-0000-0000-000000000001';
    const schedule = '50f207a3-848d-4610-998d-850453c2025d';
    final draft = StudentTransportDraft(
      enrollmentId: enrollment,
      schoolId: school,
      allocations: {(weekday: 1, direction: 'going'): schedule},
      effectiveOn: '2026-10-06',
      expectedRoutingRevision: 1,
    );

    http.Response receipt(http.Request request, {String command = testId, String enrollmentId = enrollment}) =>
        http.Response(
          jsonEncode([
            {
              'command_id': command,
              'enrollment_id': enrollmentId,
              'routing_revision': 2,
              'effective_on': '2026-10-06',
            },
          ]),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );

    test('sends the exact direct-allocation RPC and returns the new revision', () async {
      final client = await planningClient((request) async {
        expect(request.url.path, endsWith('/rpc/assign_fleet_student_transport'));
        expect(jsonDecode(request.body), {
          'p_enrollment_id': enrollment,
          'p_school_id': school,
          'p_allocations': [
            {'schedule_id': schedule, 'weekday': 1, 'direction': 'going'},
          ],
          'p_effective_on': '2026-10-06',
          'p_command_id': testId,
          'p_expected_routing_revision': 1,
        });
        return receipt(request);
      });
      addTearDown(client.dispose);
      expect(await FleetPlanningService(client: client).assignStudentTransport(draft, testId), 2);
    });

    test('rejects a receipt for another command or enrollment', () async {
      for (final mismatch in [
        (command: '22222222-2222-4222-8222-222222222222', enrollmentId: enrollment),
        (command: testId, enrollmentId: '22222222-2222-4222-8222-222222222222'),
      ]) {
        final client = await planningClient(
          (request) async => receipt(request, command: mismatch.command, enrollmentId: mismatch.enrollmentId),
        );
        addTearDown(client.dispose);
        await expectLater(
          FleetPlanningService(client: client).assignStudentTransport(draft, testId),
          throwsFormatException,
        );
      }
    });

    test('requires an authenticated session', () async {
      final service = FleetPlanningService(
        client: SupabaseClient('https://example.supabase.co', 'test-key'),
      );
      await expectLater(service.assignStudentTransport(draft, testId), throwsA(isA<AuthException>()));
    });
  });
```

- [ ] **Step 2: Write the failing mapper test** — append inside `main()` of `fleet_planning_error_mapper_test.dart`:

```dart
  test('direct allocation codes are safe pt-BR rejections', () {
    for (final (code, text) in [
      ('effective_date_conflict', 'A data de início não está disponível para esta programação. Escolha outra data.'),
      ('invalid_transition', 'Esta ação não está disponível no estado atual do cadastro.'),
      ('schedule_conflict', 'Este horário conflita com outra programação.'),
    ]) {
      final error = PostgrestException(message: 'secret', code: code);
      expect(PlanningErrorMapper.kind(error), PlanningFailure.rejected);
      expect(PlanningErrorMapper.message(error), text);
    }
    // allocation_failed is an unexpected 500: keep the command id and verify again.
    expect(
      PlanningErrorMapper.kind(const PostgrestException(message: 'x', code: 'allocation_failed')),
      PlanningFailure.uncertain,
    );
  });
```

- [ ] **Step 3: Run to verify RED**

Run: `cd vango_app && flutter test test/unit/features/fleet/fleet_planning_service_test.dart test/unit/features/fleet/fleet_planning_error_mapper_test.dart`
Expected: compile FAIL `The method 'assignStudentTransport' isn't defined`; after a temporary stub, the mapper test FAILS on `effective_date_conflict` kind (`uncertain` ≠ `rejected`).

- [ ] **Step 4: Implement the service method** in `fleet_planning_service.dart` (add `import '../models/fleet_student_transport.dart';`), next to `saveSchedule`:

```dart
  /// Replaces an owner-registered student's weekly plan from the draft's date.
  /// Only a matching backend receipt counts as success; returns the new revision.
  Future<int> assignStudentTransport(
    StudentTransportDraft draft,
    String commandId,
  ) async {
    final rows = await _authenticated.rpc(
      'assign_fleet_student_transport',
      params: draft.toRpcParams(commandId),
    );
    if (rows is! List || rows.length != 1) {
      throw const PlanningResponseFormatException('transport receipt');
    }
    final row = planningObject(rows.single, 'transport receipt');
    if (planningId(row, 'command_id') != commandId ||
        planningId(row, 'enrollment_id') != draft.enrollmentId) {
      throw const PlanningResponseFormatException('transport receipt');
    }
    return planningInt(row, 'routing_revision', 1);
  }
```

- [ ] **Step 5: Extend the mapper** in `fleet_planning_error_mapper.dart`:
  - In `kind`, add `'effective_date_conflict' ||` to the `PlanningFailure.rejected` arm (leave `allocation_failed` unmapped → `uncertain`).
  - In `message`, change `schedule_conflict` text and add two arms before the `_` default:

```dart
    'schedule_conflict' => 'Este horário conflita com outra programação.',
    'effective_date_conflict' =>
      'A data de início não está disponível para esta programação. Escolha outra data.',
    'invalid_transition' =>
      'Esta ação não está disponível no estado atual do cadastro.',
```

  Before changing the `schedule_conflict` text, confirm no test asserts the old copy: `grep -rn "Este horário conflita com outra rota" vango_app` must return only the mapper line.

- [ ] **Step 6: Run to verify GREEN**

Run: `cd vango_app && flutter test test/unit/features/fleet`
Expected: all PASS.

- [ ] **Step 7: Commit (once authorized)**

```bash
git add vango_app/lib/features/fleet/services vango_app/test/unit/features/fleet/fleet_planning_service_test.dart vango_app/test/unit/features/fleet/fleet_planning_error_mapper_test.dart
git commit -m "feat(fleet): call direct student transport allocation RPC"
```

---

### Task 4: Student transport screen — read path (render, empty states, saved plan, access)

**Files:**
- Create: `vango_app/lib/features/fleet/screens/fleet_student_transport_screen.dart`
- Test: `vango_app/test/widget/features/fleet/fleet_student_transport_screen_test.dart`

**Interfaces:**
- Consumes: Tasks 1–3; `AuthService` (`currentSession`, `authStateChanges`, `getMyAccessContext()` → `AccessContext.ownerFleetIds`), `createFleetCommandId()` from `models/fleet_command_id.dart`, `AppColors` from `core/theme/app_colors.dart`.
- Produces:
  ```dart
  class FleetStudentTransportScreen extends StatefulWidget {
    const FleetStudentTransportScreen({
      super.key,
      required String fleetId,
      required String userId,
      required OwnerEnrolledStudent student,
      required AuthService authService,
      FleetPlanningService? service,
      DateTime Function() clock = DateTime.now,
    });
  }
  ```
  Widget keys used by tests: `ValueKey('transport-slot-<weekday>-<direction>')` on a `KeyedSubtree` wrapping each slot dropdown.

**UI contract (pt-BR copy, exact strings — tests depend on them):**

| Element | Text |
| --- | --- |
| AppBar title | `Programar transporte` |
| School line | `Escola: <schoolName>` or `Escola: não definida` |
| Shift line | `Turno: Manhã/Tarde/Noite/Integral` or `Turno: não definido` |
| Missing school/shift | `Defina a escola e o turno do aluno antes de programar o transporte.` |
| Saved section title | `Programação salva` |
| Saved empty | `Nenhuma programação salva.` |
| Saved row | `<Seg> · <Ida> · <route name> · <dd/MM/yyyy> a <dd/MM/yyyy>` |
| Date tile | title `Início da programação`, subtitle `dd/MM/yyyy`, button `Alterar data` |
| Slot label | `<Seg|Ter|Qua|Qui|Sex|Sáb|Dom> · <Ida|Volta>` |
| Slot items | `Sem transporte`, `<route name> · <HH:mm>` |
| No compatible slot | `Nenhuma rota compatível com a escola e o turno deste aluno nesta data. Configure rotas e horários no planejamento da frota.` |
| Submit | `Salvar programação` (`Salvando...` while submitting; disabled when nothing is selected) |
| Success snackbar | `Programação salva.` |
| Access lost | `Seu acesso à frota não está disponível.` |
| Read error | `Não foi possível carregar o planejamento.` + button `Tentar novamente` |
| Reload failed after data shown | `Não foi possível atualizar a programação salva.` + button `Tentar novamente` |

- [ ] **Step 1: Write the failing widget tests (read path)** — create the test file with the shared fake and helpers (Task 5 appends to this same file):

```dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:vango_app/features/auth/models/access_context.dart';
import 'package:vango_app/features/fleet/models/fleet_planning.dart';
import 'package:vango_app/features/fleet/models/fleet_student_transport.dart';
import 'package:vango_app/features/fleet/screens/fleet_student_transport_screen.dart';
import 'package:vango_app/features/fleet/services/fleet_planning_service.dart';
import 'package:vango_app/features/fleet/services/fleet_service.dart';
import '../../../support/fake_auth_service.dart';
import '../../../unit/features/fleet/fleet_planning_test.dart';
import '../../../unit/features/fleet/fleet_student_transport_test.dart'
    show reservationRow, enrollmentId, schoolId, goingSchedule, returnSchedule, goingRoute;

const OwnerEnrolledStudent transportStudent = (
  id: 'student-a',
  enrollmentId: enrollmentId,
  fullName: 'Ana Silva',
  address: 'Rua, 1 - Centro, Cidade',
  schoolId: schoolId,
  schoolName: 'Escola Ciclo 3',
  shift: 'morning',
);

DateTime monday() => DateTime(2026, 10, 5);

/// Records direct-allocation writes and serves a mutable planning projection.
class FakeTransportPlanningService extends FleetPlanningService {
  FakeTransportPlanningService()
    : super(
        client: SupabaseClient(
          'https://example.test',
          'test',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        ),
      );
  Map<String, dynamic> planningJson = planningFixture();
  Object? loadError;
  int loads = 0;
  final writes = <({StudentTransportDraft draft, String commandId})>[];

  /// Each entry is consumed by one write: `null` succeeds, anything else is thrown.
  final writeResults = <Object?>[];

  @override
  String? get currentUserId => 'user';

  @override
  Future<FleetPlanning> load(String fleetId) async {
    loads++;
    if (loadError case final error?) throw error;
    return FleetPlanning.fromJson(planningJson);
  }

  @override
  Future<int> assignStudentTransport(
    StudentTransportDraft draft,
    String commandId,
  ) async {
    writes.add((draft: draft, commandId: commandId));
    final result = writeResults.isEmpty ? null : writeResults.removeAt(0);
    if (result != null) throw result;
    return draft.expectedRoutingRevision + 1;
  }
}

AccessContext ownerOf(List<String> fleets) => AccessContext(
  onboardingIntent: null,
  accountRoles: const {AccountRole.owner},
  dependentStudentIds: const [],
  adultStudentId: null,
  fleetAccess: [
    for (final fleet in fleets)
      FleetAccess(fleetId: fleet, roles: const {AccountRole.owner}),
  ],
);

Future<void> pumpTransport(
  WidgetTester tester,
  FakeTransportPlanningService service, {
  OwnerEnrolledStudent student = transportStudent,
  List<String> ownedFleets = const ['fleet'],
  DateTime Function() clock = monday,
}) async {
  final auth = FakeAuthService.signedIn(
    userId: 'user',
    accessContext: ownerOf(ownedFleets),
  );
  addTearDown(auth.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: FleetStudentTransportScreen(
        fleetId: 'fleet',
        userId: 'user',
        student: student,
        authService: auth,
        service: service,
        clock: clock,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder slot(int weekday, String direction) =>
    find.byKey(ValueKey('transport-slot-$weekday-$direction'));

Future<void> choose(
  WidgetTester tester,
  int weekday,
  String direction,
  String label,
) async {
  await tester.ensureVisible(slot(weekday, direction));
  await tester.tap(slot(weekday, direction));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Future<void> save(WidgetTester tester) async {
  await tester.ensureVisible(find.text('Salvar programação'));
  await tester.tap(find.text('Salvar programação'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders only slots with compatible schedules for school and shift', (tester) async {
    await pumpTransport(tester, FakeTransportPlanningService());
    expect(find.text('Programar transporte'), findsOneWidget);
    expect(find.text('Escola: Escola Ciclo 3'), findsOneWidget);
    expect(find.text('Turno: Manhã'), findsOneWidget);
    expect(find.text('06/10/2026'), findsOneWidget); // tomorrow suggested
    for (var weekday = 1; weekday <= 5; weekday++) {
      expect(slot(weekday, 'going'), findsOneWidget);
      expect(slot(weekday, 'return'), findsOneWidget);
    }
    expect(slot(6, 'going'), findsNothing);
    expect(slot(7, 'return'), findsNothing);

    await tester.tap(slot(1, 'going'));
    await tester.pumpAndSettle();
    expect(find.text('Ciclo 3 ida · 08:00'), findsWidgets);
    expect(find.text('Ciclo 3 volta · 16:00'), findsNothing);
  });

  testWidgets('shows an empty state when no route serves the student shift', (tester) async {
    const OwnerEnrolledStudent student = (
      id: 'student-a',
      enrollmentId: enrollmentId,
      fullName: 'Ana Silva',
      address: 'Rua',
      schoolId: schoolId,
      schoolName: 'Escola Ciclo 3',
      shift: 'afternoon',
    );
    await pumpTransport(tester, FakeTransportPlanningService(), student: student);
    expect(
      find.text(
        'Nenhuma rota compatível com a escola e o turno deste aluno nesta data. Configure rotas e horários no planejamento da frota.',
      ),
      findsOneWidget,
    );
    final button = tester.widget<ElevatedButton>(find.widgetWithText(ElevatedButton, 'Salvar programação'));
    expect(button.onPressed, isNull);
  });

  testWidgets('blocks allocation when the enrollment has no school or shift', (tester) async {
    const OwnerEnrolledStudent student = (
      id: 'student-a',
      enrollmentId: enrollmentId,
      fullName: 'Ana Silva',
      address: 'Rua',
      schoolId: null,
      schoolName: null,
      shift: null,
    );
    await pumpTransport(tester, FakeTransportPlanningService(), student: student);
    expect(find.text('Escola: não definida'), findsOneWidget);
    expect(
      find.text('Defina a escola e o turno do aluno antes de programar o transporte.'),
      findsOneWidget,
    );
    expect(find.text('Salvar programação'), findsNothing);
  });

  testWidgets('a fresh screen renders and preselects the persisted allocation', (tester) async {
    final service = FakeTransportPlanningService()
      ..planningJson['reservations'] = [
        reservationRow(weekday: 1, direction: 'going', scheduleId: goingSchedule, routeId: goingRoute),
      ];
    await pumpTransport(tester, service);
    expect(find.text('Programação salva'), findsOneWidget);
    expect(find.text('Seg · Ida · Ciclo 3 ida · 06/10/2026 a 25/12/2026'), findsOneWidget);
    expect(
      find.descendant(of: slot(1, 'going'), matching: find.text('Ciclo 3 ida · 08:00')),
      findsOneWidget,
    );
  });

  testWidgets('shows that nothing is saved yet', (tester) async {
    await pumpTransport(tester, FakeTransportPlanningService());
    expect(find.text('Nenhuma programação salva.'), findsOneWidget);
  });

  testWidgets('a non-owner never reads planning', (tester) async {
    final service = FakeTransportPlanningService();
    await pumpTransport(tester, service, ownedFleets: const []);
    expect(find.text('Seu acesso à frota não está disponível.'), findsOneWidget);
    expect(service.loads, 0);
  });

  testWidgets('read failure offers a retry that loads again', (tester) async {
    final service = FakeTransportPlanningService()..loadError = Exception('offline');
    await pumpTransport(tester, service);
    expect(find.text('Não foi possível carregar o planejamento.'), findsOneWidget);
    service.loadError = null;
    await tester.tap(find.text('Tentar novamente'));
    await tester.pumpAndSettle();
    expect(slot(1, 'going'), findsOneWidget);
    expect(service.loads, 2);
  });
}
```

Note: `returnSchedule` is imported for Task 5; if the analyzer flags it unused before Task 5, add Task 5 tests in the same session or drop it from the `show` list temporarily.

- [ ] **Step 2: Run to verify RED**

Run: `cd vango_app && flutter test test/widget/features/fleet/fleet_student_transport_screen_test.dart`
Expected: compile FAIL — `Target of URI doesn't exist: '.../fleet_student_transport_screen.dart'`.

- [ ] **Step 3: Implement the screen** (read and write path in one file; the write path is exercised in Task 5). Create `fleet_student_transport_screen.dart`:

```dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_colors.dart';
import '../../auth/services/auth_service.dart';
import '../models/fleet_command_id.dart';
import '../models/fleet_planning.dart';
import '../models/fleet_student_transport.dart';
import '../services/fleet_planning_error_mapper.dart';
import '../services/fleet_planning_service.dart';
import '../services/fleet_service.dart';

const _weekdayLabels = {
  1: 'Seg', 2: 'Ter', 3: 'Qua', 4: 'Qui', 5: 'Sex', 6: 'Sáb', 7: 'Dom',
};
const _directionLabels = {'going': 'Ida', 'return': 'Volta'};
const _shiftLabels = {
  'morning': 'Manhã',
  'afternoon': 'Tarde',
  'evening': 'Noite',
  'full_time': 'Integral',
};

String _displayDate(String civil) =>
    '${civil.substring(8, 10)}/${civil.substring(5, 7)}/${civil.substring(0, 4)}';

/// Weekly transport plan of one owner-registered student, read and written via RPCs.
class FleetStudentTransportScreen extends StatefulWidget {
  const FleetStudentTransportScreen({
    super.key,
    required this.fleetId,
    required this.userId,
    required this.student,
    required this.authService,
    this.service,
    this.clock = DateTime.now,
  });

  final String fleetId, userId;
  final OwnerEnrolledStudent student;
  final AuthService authService;
  final FleetPlanningService? service;

  /// Injected so tests can pin "today"; production uses the device clock.
  final DateTime Function() clock;

  @override
  State<FleetStudentTransportScreen> createState() =>
      _FleetStudentTransportScreenState();
}

class _FleetStudentTransportScreenState
    extends State<FleetStudentTransportScreen> {
  late final FleetPlanningService _service =
      widget.service ?? FleetPlanningService();
  StreamSubscription<AuthState>? _auth;
  FleetPlanning? _planning;
  Object? _readError;
  bool _loading = true, _submitting = false, _denied = false;
  late String _effectiveOn = civilDate(
    DateTime(_today.year, _today.month, _today.day + 1),
  );
  Map<TransportSlot, String> _selection = {};
  // Bumped whenever the selection is replaced programmatically, so dropdowns
  // (which only read initialValue once) are rebuilt with the new values.
  int _formVersion = 0;
  String? _message;
  // Identity of the last unconfirmed command; reused only for the same payload.
  String? _pendingKey, _pendingCommandId;
  int _readGeneration = 0;

  DateTime get _today {
    final now = widget.clock();
    return DateTime(now.year, now.month, now.day);
  }

  String? get _schoolId => widget.student.schoolId;
  String? get _shift => widget.student.shift;

  @override
  void initState() {
    super.initState();
    _auth = widget.authService.authStateChanges.listen((_) {
      if (widget.authService.currentSession?.user.id != widget.userId) {
        _deny();
      }
    });
    _load(prefill: true);
  }

  @override
  void dispose() {
    _auth?.cancel();
    super.dispose();
  }

  void _deny() {
    if (!mounted) return;
    setState(() {
      _denied = true;
      _planning = null;
      _selection = {};
      _pendingKey = _pendingCommandId = null;
    });
  }

  /// Every read and write re-checks the opening session and owner role.
  Future<void> _ensureAccess() async {
    if (widget.authService.currentSession?.user.id != widget.userId) {
      throw const AuthException('Session changed');
    }
    final access = await widget.authService.getMyAccessContext();
    if (!access.ownerFleetIds.contains(widget.fleetId)) {
      throw const PostgrestException(
        message: 'Owner access required',
        code: 'forbidden',
      );
    }
  }

  Future<void> _load({bool prefill = false}) async {
    final read = ++_readGeneration;
    setState(() {
      _loading = true;
      _readError = null;
    });
    try {
      await _ensureAccess();
      final planning = await _service.load(widget.fleetId);
      if (!mounted || _denied || read != _readGeneration) return;
      setState(() {
        _planning = planning;
        if (prefill) {
          _selection = allocationsInEffect(
            planning,
            widget.student.enrollmentId,
            _effectiveOn,
          );
        }
        _dropIncompatible();
        _formVersion++;
      });
    } catch (error) {
      if (!mounted || read != _readGeneration) return;
      if (PlanningErrorMapper.kind(error) == PlanningFailure.accessLost) {
        _deny();
        return;
      }
      setState(() => _readError = error);
    } finally {
      if (mounted && read == _readGeneration) {
        setState(() => _loading = false);
      }
    }
  }

  List<TransportOption> _options(TransportSlot slot) {
    final planning = _planning, school = _schoolId, shift = _shift;
    if (planning == null || school == null || shift == null) return const [];
    return compatibleTransportOptions(
      planning,
      schoolId: school,
      shift: shift,
      slot: slot,
      effectiveOn: _effectiveOn,
    );
  }

  /// A choice that is no longer compatible (date or planning changed) is discarded.
  void _dropIncompatible() {
    _selection.removeWhere(
      (slot, scheduleId) =>
          !_options(slot).any((option) => option.schedule.id == scheduleId),
    );
  }

  Future<void> _pickDate() async {
    final today = _today;
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.parse(_effectiveOn),
      firstDate: today,
      lastDate: DateTime(today.year + 1, today.month, today.day),
      helpText: 'Início da programação',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _effectiveOn = civilDate(picked);
      _dropIncompatible();
      _formVersion++;
    });
  }

  Future<void> _submit() async {
    final planning = _planning, school = _schoolId;
    if (planning == null || school == null || _selection.isEmpty) return;
    if (_submitting) return;
    final revision =
        planning.enrollmentRevisions[widget.student.enrollmentId];
    if (revision == null) {
      setState(
        () => _message =
            'Este aluno não está mais ativo na frota. Recarregue a lista de alunos.',
      );
      return;
    }
    final draft = StudentTransportDraft(
      enrollmentId: widget.student.enrollmentId,
      schoolId: school,
      allocations: _selection,
      effectiveOn: _effectiveOn,
      expectedRoutingRevision: revision,
    );
    // An unconfirmed write is retried with the same id (backend replays the
    // receipt); any change to the payload is a new logical command.
    final key = draft.payloadKey;
    final commandId = key == _pendingKey
        ? _pendingCommandId!
        : createFleetCommandId();
    _pendingKey = key;
    _pendingCommandId = commandId;
    setState(() {
      _submitting = true;
      _message = null;
    });
    try {
      await _ensureAccess();
      await _service.assignStudentTransport(draft, commandId);
      if (!mounted) return;
      _pendingKey = _pendingCommandId = null;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Programação salva.')));
      await _load(); // the saved plan always comes from the backend projection
    } catch (error) {
      if (!mounted) return;
      final kind = PlanningErrorMapper.kind(error);
      if (kind == PlanningFailure.accessLost) {
        _deny();
        return;
      }
      if (kind != PlanningFailure.uncertain) {
        _pendingKey = _pendingCommandId = null;
      }
      setState(() => _message = PlanningErrorMapper.message(error));
      if (error is PostgrestException && error.code == 'revision_conflict') {
        await _load();
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundWhite,
      appBar: AppBar(title: const Text('Programar transporte')),
      body: _body(),
    );
  }

  Widget _body() {
    if (_denied) {
      return const Center(child: Text('Seu acesso à frota não está disponível.'));
    }
    final planning = _planning;
    if (planning == null) {
      if (_loading) return const Center(child: CircularProgressIndicator());
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Não foi possível carregar o planejamento.'),
            ElevatedButton(
              onPressed: () => _load(prefill: true),
              child: const Text('Tentar novamente'),
            ),
          ],
        ),
      );
    }
    final student = widget.student;
    final ready = _schoolId != null && _shift != null;
    final slots = [
      for (final slot in transportSlots)
        if (_options(slot).isNotEmpty) slot,
    ];
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          student.fullName,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
        ),
        Text('Escola: ${student.schoolName ?? 'não definida'}'),
        Text('Turno: ${_shiftLabels[student.shift] ?? 'não definido'}'),
        const SizedBox(height: 16),
        if (!ready)
          const Text(
            'Defina a escola e o turno do aluno antes de programar o transporte.',
          )
        else ...[
          if (_readError != null)
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Não foi possível atualizar a programação salva.',
                    style: TextStyle(color: AppColors.errorRed),
                  ),
                ),
                TextButton(
                  onPressed: _load,
                  child: const Text('Tentar novamente'),
                ),
              ],
            ),
          ..._saved(planning),
          const SizedBox(height: 16),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Início da programação'),
            subtitle: Text(_displayDate(_effectiveOn)),
            trailing: TextButton(
              onPressed: _submitting ? null : _pickDate,
              child: const Text('Alterar data'),
            ),
          ),
          if (slots.isEmpty)
            const Text(
              'Nenhuma rota compatível com a escola e o turno deste aluno nesta data. Configure rotas e horários no planejamento da frota.',
            )
          else
            for (final slot in slots) _slotField(slot),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _message!,
                style: const TextStyle(color: AppColors.errorRed),
              ),
            ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: _selection.isEmpty || _submitting ? null : _submit,
            child: Text(_submitting ? 'Salvando...' : 'Salvar programação'),
          ),
        ],
      ],
    );
  }

  List<Widget> _saved(FleetPlanning planning) {
    final names = {for (final route in planning.routes) route.id: route.name};
    final rows = savedStudentReservations(
      planning,
      widget.student.enrollmentId,
      civilDate(_today),
    );
    return [
      const Text(
        'Programação salva',
        style: TextStyle(fontWeight: FontWeight.bold),
      ),
      if (rows.isEmpty)
        const Text(
          'Nenhuma programação salva.',
          style: TextStyle(color: AppColors.textMuted),
        ),
      for (final row in rows)
        Text(
          '${_weekdayLabels[row['weekday']]} · '
          '${_directionLabels[row['direction']]} · '
          '${names[row['route_id']] ?? 'Rota'} · '
          '${_displayDate(row['valid_from']! as String)} a '
          '${_displayDate(row['valid_until']! as String)}',
        ),
    ];
  }

  Widget _slotField(TransportSlot slot) {
    final options = _options(slot);
    return KeyedSubtree(
      key: ValueKey('transport-slot-${slot.weekday}-${slot.direction}'),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: DropdownButtonFormField<String?>(
          key: ValueKey('${slot.weekday}-${slot.direction}-$_formVersion'),
          initialValue: _selection[slot],
          isExpanded: true,
          decoration: InputDecoration(
            labelText:
                '${_weekdayLabels[slot.weekday]} · ${_directionLabels[slot.direction]}',
          ),
          items: [
            const DropdownMenuItem<String?>(
              value: null,
              child: Text('Sem transporte'),
            ),
            for (final option in options)
              DropdownMenuItem<String?>(
                value: option.schedule.id,
                child: Text(
                  '${option.route.name} · ${option.schedule.startsAt.substring(0, 5)}',
                ),
              ),
          ],
          onChanged: _submitting
              ? null
              : (value) => setState(() {
                  if (value == null) {
                    _selection.remove(slot);
                  } else {
                    _selection[slot] = value;
                  }
                }),
        ),
      ),
    );
  }
}
```

Implementation notes for sensitive points:
- `_selection` must be a **mutable** map. `allocationsInEffect` returns a map literal (mutable); never assign `draft.allocations` (unmodifiable) back to `_selection`.
- `_load` calls `setState` before the first `await`. This is legal from `initState` (the element is mounted). If a lint or assert complains, initialize `_loading = true` (already the default) and guard the first `setState` with `if (read > 1)`.
- `_readGeneration` discards stale responses when the owner taps retry twice (same pattern as `FleetPlanningController.load`).
- `_denied` is sticky: once access is lost the screen never shows data again; the owner must reopen it.

- [ ] **Step 4: Run to verify GREEN**

Run: `cd vango_app && flutter test test/widget/features/fleet/fleet_student_transport_screen_test.dart`
Expected: all 7 read-path tests PASS. If `find.text('Ciclo 3 ida · 08:00')` after opening the menu finds 2 widgets, that is expected for Material dropdowns (the button and the overlay item) — the test uses `findsWidgets`.

- [ ] **Step 5: Format, analyze, commit (once authorized)**

```bash
cd vango_app && dart format lib/features/fleet/screens/fleet_student_transport_screen.dart test/widget/features/fleet/fleet_student_transport_screen_test.dart && flutter analyze
git add vango_app/lib/features/fleet/screens/fleet_student_transport_screen.dart vango_app/test/widget/features/fleet/fleet_student_transport_screen_test.dart
git commit -m "feat(fleet): show compatible schedules and saved plan for a fleet student"
```

---

### Task 5: Student transport screen — write path (submit, date choice, errors, idempotency)

**Files:**
- Test: `vango_app/test/widget/features/fleet/fleet_student_transport_screen_test.dart` (append to `main()`)
- Modify only if a test fails: `vango_app/lib/features/fleet/screens/fleet_student_transport_screen.dart`

**Interfaces:**
- Consumes: everything from Task 4 (helpers `pumpTransport`, `choose`, `save`, `slot`, `FakeTransportPlanningService`).

The write path code already exists from Task 4 Step 3. These tests are still written first and run individually; **if one passes immediately, record that it was GREEN on first run (do not manufacture a RED)**. If one fails, fix the screen minimally.

- [ ] **Step 1: Write the multi-day success test**

```dart
  testWidgets('saves a multi-day allocation with the suggested date and reloads from backend', (tester) async {
    final service = FakeTransportPlanningService();
    await pumpTransport(tester, service);
    await choose(tester, 1, 'going', 'Ciclo 3 ida · 08:00');
    await choose(tester, 1, 'return', 'Ciclo 3 volta · 16:00');
    await choose(tester, 3, 'going', 'Ciclo 3 ida · 08:00');
    await save(tester);

    final write = service.writes.single;
    expect(write.draft.effectiveOn, '2026-10-06');
    expect(write.draft.schoolId, schoolId);
    expect(write.draft.expectedRoutingRevision, 1);
    expect(write.draft.allocations, {
      (weekday: 1, direction: 'going'): goingSchedule,
      (weekday: 1, direction: 'return'): returnSchedule,
      (weekday: 3, direction: 'going'): goingSchedule,
    });
    expect(find.text('Programação salva.'), findsOneWidget);
    expect(service.loads, 2);
  });
```

- [ ] **Step 2: Write the owner-chosen date test**

```dart
  testWidgets('owner can replace the suggested start date', (tester) async {
    final service = FakeTransportPlanningService();
    await pumpTransport(tester, service);
    await tester.ensureVisible(find.text('Alterar data'));
    await tester.tap(find.text('Alterar data'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('12'));
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('12/10/2026'), findsOneWidget);

    await choose(tester, 1, 'going', 'Ciclo 3 ida · 08:00');
    await save(tester);
    expect(service.writes.single.draft.effectiveOn, '2026-10-12');
  });

  testWidgets('a date outside schedule validity drops choices and shows the empty state', (tester) async {
    final service = FakeTransportPlanningService();
    // Today 2026-12-24 -> suggested 2026-12-25, the last valid schedule day.
    await pumpTransport(tester, service, clock: () => DateTime(2026, 12, 24));
    await choose(tester, 5, 'going', 'Ciclo 3 ida · 08:00'); // 2026-12-25 is a Friday
    await tester.ensureVisible(find.text('Alterar data'));
    await tester.tap(find.text('Alterar data'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('26')); // picker opens on December 2026
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('26/12/2026'), findsOneWidget);
    expect(find.textContaining('Nenhuma rota compatível'), findsOneWidget);
    final button = tester.widget<ElevatedButton>(find.widgetWithText(ElevatedButton, 'Salvar programação'));
    expect(button.onPressed, isNull);
  });
```

Note: the default test locale is `en_US`, so the Material date picker confirm button is `OK`. The app copy is pt-BR but the Material picker follows the test locale; do not assert picker chrome strings beyond `OK`.

- [ ] **Step 3: Write the rejection tests (capacity, stale, date)**

```dart
  testWidgets('capacity conflict is shown, never reported as success, and a retry is a new command', (tester) async {
    final service = FakeTransportPlanningService()
      ..writeResults.add(const PostgrestException(message: 'full', code: 'capacity_exceeded'));
    await pumpTransport(tester, service);
    await choose(tester, 1, 'going', 'Ciclo 3 ida · 08:00');
    await save(tester);
    expect(find.text('A capacidade disponível não atende à programação.'), findsOneWidget);
    expect(find.text('Programação salva.'), findsNothing);

    await save(tester);
    expect(service.writes, hasLength(2));
    expect(service.writes.last.commandId, isNot(service.writes.first.commandId));
  });

  testWidgets('revision conflict reloads planning and keeps the owner choices', (tester) async {
    final service = FakeTransportPlanningService()
      ..writeResults.add(const PostgrestException(message: 'stale', code: 'revision_conflict'));
    await pumpTransport(tester, service);
    await choose(tester, 2, 'going', 'Ciclo 3 ida · 08:00');
    await save(tester);
    expect(
      find.text('Esta configuração foi alterada. Recarregue e revise antes de salvar.'),
      findsOneWidget,
    );
    expect(service.loads, 2);
    expect(
      find.descendant(of: slot(2, 'going'), matching: find.text('Ciclo 3 ida · 08:00')),
      findsOneWidget,
    );
  });

  testWidgets('stale or incompatible schedule and closed dates are surfaced', (tester) async {
    final service = FakeTransportPlanningService()
      ..writeResults.addAll(const [
        PostgrestException(message: 'gone', code: 'invalid_input'),
        PostgrestException(message: 'closed', code: 'effective_date_conflict'),
      ]);
    await pumpTransport(tester, service);
    await choose(tester, 1, 'going', 'Ciclo 3 ida · 08:00');
    await save(tester);
    expect(find.text('Revise os campos e a cobertura da frota.'), findsOneWidget);
    await save(tester);
    expect(
      find.text('A data de início não está disponível para esta programação. Escolha outra data.'),
      findsOneWidget,
    );
    expect(find.text('Programação salva.'), findsNothing);
  });
```

- [ ] **Step 4: Write the uncertain-outcome idempotency test**

```dart
  testWidgets('an unconfirmed write reuses its command id until the payload changes', (tester) async {
    final service = FakeTransportPlanningService()
      ..writeResults.addAll([Exception('socket closed'), Exception('socket closed')]);
    await pumpTransport(tester, service);
    await choose(tester, 1, 'going', 'Ciclo 3 ida · 08:00');
    await save(tester);
    expect(
      find.text('Não foi possível confirmar o envio. Tente verificar novamente.'),
      findsOneWidget,
    );
    expect(find.text('Programação salva.'), findsNothing);

    await save(tester); // same payload -> same id
    expect(service.writes[1].commandId, service.writes[0].commandId);

    await choose(tester, 1, 'return', 'Ciclo 3 volta · 16:00');
    await save(tester); // changed payload -> new id, succeeds
    expect(service.writes[2].commandId, isNot(service.writes[0].commandId));
    expect(find.text('Programação salva.'), findsOneWidget);
  });

  testWidgets('losing owner access during a write hides the plan', (tester) async {
    final service = FakeTransportPlanningService()
      ..writeResults.add(const PostgrestException(message: 'gone', code: 'not_found'));
    await pumpTransport(tester, service);
    await choose(tester, 1, 'going', 'Ciclo 3 ida · 08:00');
    await save(tester);
    expect(find.text('Seu acesso à frota não está disponível.'), findsOneWidget);
    expect(find.text('Salvar programação'), findsNothing);
  });
```

- [ ] **Step 5: Run each new test, record RED/GREEN, fix minimally**

Run: `cd vango_app && flutter test test/widget/features/fleet/fleet_student_transport_screen_test.dart`
Expected: all PASS. Known pitfalls if something fails:
- Snackbar text not found → `pumpAndSettle` in `save()` must run after the snackbar is shown; the snackbar stays ~4 s, so it is visible right after `save`.
- Dropdown selection lost after reload → confirm `_load()` without `prefill` keeps `_selection` and only `_dropIncompatible()` runs.
- Same id not reused → confirm `_pendingKey` is not cleared in the `uncertain` branch.

- [ ] **Step 6: Commit (once authorized)**

```bash
git add vango_app/test/widget/features/fleet/fleet_student_transport_screen_test.dart vango_app/lib/features/fleet/screens/fleet_student_transport_screen.dart
git commit -m "test(fleet): cover direct student allocation outcomes and command reuse"
```

---

### Task 6: Open the transport screen from the owner dashboard

**Files:**
- Modify: `vango_app/lib/features/fleet/screens/fleet_owner_dashboard_screen.dart` (constructor ~line 16; student card `Row` in `_buildStudentList` ~line 700)
- Test: `vango_app/test/widget/features/fleet/fleet_owner_dashboard_screen_test.dart`

**Interfaces:**
- Consumes: `FleetStudentTransportScreen` (Task 4), `FakeTransportPlanningService` and `transportStudent` exported from the Task 4 test file.
- Produces: `FleetOwnerDashboardScreen({..., FleetPlanningService? planningService})`.

- [ ] **Step 1: Write the failing test** — add to `fleet_owner_dashboard_screen_test.dart` (imports: `package:vango_app/features/fleet/screens/fleet_student_transport_screen.dart` and `'fleet_student_transport_screen_test.dart' show FakeTransportPlanningService, transportStudent`):

```dart
  testWidgets('student card opens the transport plan for that enrollment', (tester) async {
    final auth = FakeAuthService.signedIn(
      userId: 'user-1',
      accessContext: _context('fleet-a'),
    );
    addTearDown(auth.dispose);
    final fleet = _RecordingFleetService()..students = [transportStudent];
    final planning = FakeTransportPlanningService();
    await tester.pumpWidget(
      MaterialApp(
        home: FleetOwnerDashboardScreen(
          fleetId: 'fleet-a',
          userId: 'user-1',
          authService: auth,
          fleetService: fleet,
          planningService: planning,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Alunos (1)'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Programar transporte'));
    await tester.pumpAndSettle();

    final screen = tester.widget<FleetStudentTransportScreen>(
      find.byType(FleetStudentTransportScreen),
    );
    expect(screen.fleetId, 'fleet-a');
    expect(screen.userId, 'user-1');
    expect(screen.student.enrollmentId, transportStudent.enrollmentId);
    expect(planning.loads, 1);
  });
```

- [ ] **Step 2: Run to verify RED**

Run: `cd vango_app && flutter test test/widget/features/fleet/fleet_owner_dashboard_screen_test.dart --plain-name "student card opens the transport plan"`
Expected: compile FAIL — `No named parameter with the name 'planningService'`.

- [ ] **Step 3: Implement**

Constructor and field:

```dart
  const FleetOwnerDashboardScreen({
    super.key,
    this.fleetService,
    this.planningService,
    required this.fleetId,
    required this.userId,
    required this.authService,
  });

  final FleetService? fleetService;

  /// Injected in tests; the transport screen creates its own service otherwise.
  final FleetPlanningService? planningService;
```

Imports: `import '../services/fleet_planning_service.dart';` and `import 'fleet_student_transport_screen.dart';`.

Navigation method (next to `_openRegistration`):

```dart
  Future<void> _openTransport(OwnerEnrolledStudent student) =>
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => FleetStudentTransportScreen(
            fleetId: widget.fleetId,
            userId: widget.userId,
            student: student,
            authService: widget.authService,
            service: widget.planningService,
          ),
        ),
      );
```

In `_buildStudentList`, append to the card `Row` children, after the `Expanded(...)`:

```dart
              IconButton(
                tooltip: 'Programar transporte',
                onPressed: () => _openTransport(st),
                icon: const Icon(
                  Icons.event_note_outlined,
                  color: AppColors.primaryOrangeDark,
                ),
              ),
```

- [ ] **Step 4: Run to verify GREEN, then the whole fleet suite**

Run: `cd vango_app && flutter test test/widget/features/fleet test/unit/features/fleet`
Expected: all PASS.

- [ ] **Step 5: Commit (once authorized)**

```bash
git add vango_app/lib/features/fleet/screens/fleet_owner_dashboard_screen.dart vango_app/test/widget/features/fleet/fleet_owner_dashboard_screen_test.dart
git commit -m "feat(fleet): open student transport plan from owner dashboard"
```

---

### Task 7: Quality gate and real-backend smoke check

**Files:** none new (fix only what the gate reports).

- [ ] **Step 1: Static analysis and format**

Run: `cd vango_app && flutter analyze && dart format --set-exit-if-changed lib test`
Expected: `No issues found!` and exit code 0.

- [ ] **Step 2: Full suite with coverage**

Run: `cd vango_app && flutter test --coverage`
Expected: all PASS; `coverage/lcov.info` generated.

- [ ] **Step 3: Coverage of the changed business files ≥ 80%**

Run (from `vango_app/`):

```bash
python3 - <<'EOF'
import re
targets = ["lib/features/fleet/models/fleet_student_transport.dart",
           "lib/features/fleet/services/fleet_planning_service.dart",
           "lib/features/fleet/services/fleet_planning_error_mapper.dart",
           "lib/features/fleet/services/fleet_service.dart"]
data = open("coverage/lcov.info").read().split("end_of_record")
for block in data:
    m = re.search(r"SF:(.*)", block)
    if m and m.group(1).strip() in targets:
        lf = int(re.search(r"LF:(\d+)", block).group(1)); lh = int(re.search(r"LH:(\d+)", block).group(1))
        print(f"{m.group(1).strip()}: {100*lh/lf:.1f}%")
EOF
```

Expected: each ≥ 80%. If `fleet_service.dart` is below 80% for pre-existing reasons, report the before/after numbers instead of padding tests for unrelated code.

- [ ] **Step 4: Backend regression (no SQL changed, confirm nothing drifted)**

Run (from repo root, Docker running): `supabase start && supabase db reset && supabase test db`
Expected: pgTAP suite green (the #16 tests `fleet_transport*` included). Skip with a note if Docker is unavailable; no migration was touched by this task.

- [ ] **Step 5: Manual smoke against local Supabase (optional, recommended before closing #18)**

1. `cd vango_app && flutter run` (macOS or simulator) against the local stack used by #17.
2. As an owner with a van, an active route (morning, serving school X, owner as driver) and a weekday schedule from #17, register a student at school X, shift morning.
3. Dashboard → Alunos → "Programar transporte" → pick Seg Ida/Volta → "Salvar programação" → "Programação salva." and the "Programação salva" section lists the rows.
4. Restart the app, reopen the screen: the rows and preselected dropdowns are still there (acceptance: visible after restart).
5. Verify no join request was created: `psql "$(supabase status -o env | grep DB_URL | cut -d= -f2- | tr -d '"')" -c "select count(*) from public.fleet_join_requests;"` unchanged before/after.

- [ ] **Step 6: Final commit / PR (once authorized)**

Open the PR from `claude/task-18-assign-fleet-students` into the integration branch chosen by the repo owner (note: #16/#17 live only in `codex/task-17-owner-fleet-planning`), body referencing `Closes #18` and `Part of #15`.

---

## Acceptance criteria → tasks

| Issue #18 criterion | Covered by |
| --- | --- |
| Directly enrolled student assigned to persisted route schedules | Tasks 3, 5 (multi-day success), 7 smoke |
| Assignment visible after restart | Task 4 "fresh screen renders and preselects the persisted allocation"; Task 7 step 5.4 |
| No fake join request | Only `assign_fleet_student_transport` is called (Task 3); Task 7 step 5.5 |
| Capacity conflicts surfaced | Task 5 capacity test |
| No hardcoded school/weekday/direction | School/shift from `list_fleet_students` (Task 1); slots/options from `get_fleet_planning` (Task 2) |
| Tests: compatible render / multi-day / empty / capacity / stale / failure-no-success / reload | Tasks 4 and 5 test names map 1:1 |

## Out of scope (do not build)

- Removing all allocations of a student (RPC requires ≥ 1 item).
- Choosing a school different from the enrollment's (backend rejects it).
- Showing seat availability or capacity counts in Flutter.
- Any change to `supabase/` (migrations, tests) — #19 owns trip generation.
