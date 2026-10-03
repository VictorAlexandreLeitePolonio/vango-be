# Task 20 — Load persisted service days and driver trips (plan)

GitHub: issue #20 (parent epic #15). Binding rules: `AGENTS.md`, `CONTRIBUTING.md`.

## Branch

`claude/task-20-persisted-driver-trips`, created from `claude/task-18-assign-fleet-students` (stacked;
tasks 9–18 are not on `main`). Task 19 runs in parallel in worktree `../vango-be-task-19`. No commit/push
without explicit user authorization. No `db push`.

## Decisions made with the user

1. **Visibility:** the driver home lists every trip returned by `list_service_day` (owners receive all
   fleet trips; drivers only their own — enforced by the backend). The start/operate action is shown
   only when `trip.driver_user_id == auth.uid()`; other trips render read-only.
2. **Labels come from the backend:** a new migration extends `public.get_trip` with route name, van
   plate/public name and passenger full names in the owner/driver projection only. No client-side
   joins against planning/student RPCs.
3. **Scope boundary:** start/passenger/finish remain the current local mutation in this task; task 21
   replaces them with `start_trip` / `record_passenger_event` / `finish_trip`.

## Step 1 — Backend projection (TDD)

**Red:** `supabase/tests/database/057_trip_projection_labels.test.sql` (two fleets minimum; reuse
`_helpers.psql`, `_planning.psql`, `_operations.psql` fixtures). Assert:

- fleet owner: `get_trip(id)->'trip'` has `route_name`, `van_plate`, `van_public_name` matching
  `routes.name`, `vans.plate`, `vans.public_name`; every `passengers[]` item has `student_full_name`
  matching `students.full_name`;
- assigned driver: same labels;
- driver of the same fleet not assigned to the trip: `not_found`;
- owner and driver of another fleet: `not_found` on `get_trip`, and the trip is absent from their
  `list_service_day`;
- guardian/passenger projection: no `student_full_name` key on any passenger, and no new trip label keys
  (projection unchanged);
- `list_service_day` items carry the same labels for the owner.

**Green:** `supabase migration new extend_trip_projection_labels` → `create or replace function
public.get_trip(uuid)` copied verbatim from `20260907235825_cycle_4_incidents.sql` (only definition),
changing only:

- trip object: add `'route_name'`, `'van_plate'`, `'van_public_name'` **only when `v_owner or v_driver`**
  (build the base object, then `||` the labels in that branch);
- owner/driver passenger aggregate: add `'student_full_name', st.full_name` via
  `join public.students st on st.id = p.student_id`;
- keep `security definer`, `set search_path = ''`, revoke/grant statements identical.

Verify: `supabase db reset`, `python3 supabase/tests/run_database_tests.py` (full suite, including
029/038/041 which already call `get_trip`), `supabase db lint --local --schema public,private --fail-on error`.

## Step 2 — Domain model (TDD)

Files: `vango_app/lib/features/driver/models/driver_trip.dart`, `route_stop.dart`.
Tests: `vango_app/test/unit/features/driver/driver_trip_test.dart` (new).

- `TripStatus` enum: `scheduled`, `confirmationClosed`, `active`, `completed`, `cancelled`;
  `TripStatus.fromBackend(String)` throws `FormatException` on unknown values.
- `DriverTrip.fromProjection(Map<String, dynamic>)` maps `trip.id`, `fleet_id`, `status`,
  `route_name`, `van_plate`, `planned_start_at`, `driver_user_id`, `started_at`, `ended_at`, stops and
  passengers. Remove `shift`, hardcoded title/plate.
- `RouteStop` from `stops[]`: keep backend `position` order (no reordering), `kind`
  (`origin|school|home|destination`), `latitude/longitude`, `reachedAt`; display name: `home` → the
  matching passenger `student_full_name`, `school` → `address_snapshot.name`, origin/destination →
  `address_snapshot.label`. Passenger `operation_status` attached to its `home` stop.
- Cases: each status, stop ordering preserved, home name resolution, removed passengers
  (`removed_at != null`) excluded from operable stops, unknown status error.

## Step 3 — Service (TDD)

File: `vango_app/lib/features/driver/services/driver_route_service.dart`.
Test: `vango_app/test/unit/features/driver/driver_route_service_test.dart` (rewrite).

- Delete `initialTrip`, `defaultStops`, `getTodayTrip()`, `'trip-today-001'`, fixed plate/school and
  the fixed fleet id `51000000-0000-0000-0000-000000000001`; drop the `FleetService` dependency.
- `Future<List<DriverTrip>> listTrips(DateTime serviceDate)`: fleets where the user holds `owner` or
  `driver` from the existing access-context source (`AuthService` / `get_my_access_context`), one
  `list_service_day(p_fleet_id, p_service_date)` per fleet, concatenated and sorted by
  `plannedStartAt`.
- `Future<DriverTrip> getTrip(String tripId)` → `get_trip(p_trip_id)`.
- `calculateAndOptimizeRoute` takes the loaded `DriverTrip` instead of calling `getTodayTrip()`.
- Backend failures surface as a typed exception keyed by the stable error `code` (reuse the existing
  app error-mapping helper if present); never a fallback trip.
- Cases: no fleets, no trips, one/multiple fleets and trips, sort order, backend error propagated.

## Step 4 — UI (TDD, widget tests)

Files: `vango_app/lib/features/auth/screens/authenticated_home_screen.dart` ("Minhas viagens"),
`vango_app/lib/features/driver/widgets/driver_trip_card.dart`,
`vango_app/lib/features/driver/screens/driver_route_screen.dart`.
Tests: `test/widget/features/auth/authenticated_home_screen_test.dart`,
`test/widget/features/driver/driver_trip_card_test.dart`,
`test/widget/features/driver/driver_route_screen_test.dart`.

- Home: loading → empty ("Nenhuma viagem para hoje") / error ("Não foi possível carregar suas viagens"
  + "Tentar novamente") / list of one or many trips.
- Card: route name, van plate, planned time, status label in pt-BR (Agendada, Confirmações
  encerradas, Em andamento, Concluída, Cancelada). Operate action ("Iniciar viagem" / "Continuar
  viagem") only when `driverUserId == currentUserId` and status is not terminal; otherwise read-only.
- Route screen: constructor takes `tripId`; loads `getTrip`; loading/error states; reopening restores
  backend status (active trip shows active panel).
- Cases: empty, error + retry, multiple trips, operate button hidden for another driver's trip,
  completed/cancelled read-only, active trip reload.

## Step 5 — Gates and docs

Inside `vango_app/`: `dart format --output=none --set-exit-if-changed .`, `flutter analyze` (0 issues),
`flutter test --coverage` (≥80% on driver models/services). Root: full pgTAP suite, `supabase db lint`,
`git diff --check`, `git status`. Update `vango_app/README.md` (driver trips now persisted; requires
materialized trips from task 19) and the root `README.md` status line.

## Acceptance criteria (issue #20)

- [ ] No synthetic driver trip remains.
- [ ] Home and route screen use persisted authorized trips.
- [ ] Restarting the app restores backend trip status.
- [ ] Trip state mapping matches backend states.
- [ ] Flutter tests and analysis pass; pgTAP suite and lint pass.
