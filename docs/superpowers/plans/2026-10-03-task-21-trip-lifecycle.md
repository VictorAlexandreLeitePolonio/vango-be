# Task 21 — Persist real trip lifecycle and passenger events (handoff)

GitHub: issue #21 (parent epic #15). Read `AGENTS.md` and `CONTRIBUTING.md` first — they are binding
(TDD Red→Green→Refactor, en-US code/comments/tests, pt-BR UI copy, zero analyzer issues).

## 0. Workspace — do this first, exactly

Two other agents work in parallel: task 19 in `/Users/victorpolonio/Desktop/vango-be` (main checkout)
and task 22 in `/Users/victorpolonio/Desktop/vango-be-task-20`. **Never run git commands that change
branches, stash, reset or checkout files in either of those directories.** Create your own worktree
from the already-existing branch:

```bash
cd /Users/victorpolonio/Desktop/vango-be
git worktree add ../vango-be-task-21 claude/task-21-trip-lifecycle
cd ../vango-be-task-21/vango_app && flutter pub get
```

- `claude/task-21-trip-lifecycle` already points at commit `d4c7088` (task 20). Tasks 9–20 are not on
  `main`; the PR (when authorized) targets `claude/task-20-persisted-driver-trips`.
- `flutter pub get` may rewrite `vango_app/pubspec.lock` with transitive hash drift. **Do not commit
  `pubspec.lock`**: `git checkout -- vango_app/pubspec.lock` before committing.
- Never commit/push without explicit user authorization. Conventional Commits, en-US, ending with
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Never run `supabase db push` or touch the remote project. The local Supabase stack is **shared** with
  the other agents: do **not** run `supabase db reset` without asking the user; apply your migration
  with `supabase migration up --local`.
- **Do not edit** `vango_app/lib/features/driver/services/driver_location_service.dart`, the GPS
  mode toggle/pill in `driver_route_screen.dart`, or `mapbox_*` files — task 22 owns them. Keep the
  existing `_locationService.startTracking(...)` / `stopTracking()` calls; only move *when* they run
  (see §4).
- `dart format --set-exit-if-changed .` fails on ~21 files that were already unformatted on the base
  branch (e.g. `student/`, `mapbox_directions_service.dart`). Format **only files you touch**
  (`dart format <paths>`); do not reformat unrelated files.

## 1. Decisions already made with the user (do not re-litigate)

1. Lifecycle goes through the existing RPCs; nothing is shown as done before the backend accepts it;
   after every successful command the screen reloads `get_trip`.
2. **Fleet-managed students are confirmed by default (opt-out)** via a backend trigger (§2).
3. **Going direction** (home stops before the school): home stop → "Embarcou" (`boarded`) /
   "Ausente" (`absent`); school stop → "Confirmar chegada na escola" = `mark_trip_stop_reached(school)`
   then `record_passenger_event(dropped_off)` for every `boarded` passenger; then "Finalizar viagem".
4. **Return direction** (school before home stops): while at the school, each waiting passenger can
   be marked "Ausente"; school stop → "Embarcar presentes" = `mark_trip_stop_reached(school)` then
   `record_passenger_event(boarded)` for every `waiting` passenger; each home stop → "Desembarcou"
   (`dropped_off`); then "Finalizar viagem".
5. **Uncertain outcome** (network error/timeout/5xx/unknown): keep the logical action's pending
   command id(s), reload `get_trip`; if the reload shows the action applied, drop the pending ids;
   otherwise show "Não foi possível confirmar a ação. Tente novamente." and the retry **reuses the same
   command id(s)**. A definitive backend rejection drops the ids and shows the mapped message. A new
   user action (after success or rejection) always gets a new command id.
6. Trip cancellation UI is out of scope.

## 2. Backend — fleet-managed auto-confirmation (TDD)

### Facts

- `public.trip_passengers.confirmation_status` ∈ `pending|confirmed|declined|expired`, default
  `pending`; check constraint requires `confirmation_by`/`confirmation_at` null **only** when pending.
- `private.apply_passenger_event` (migration `20260907235844_cycle_6_offline.sql`) allows `boarded`/
  `absent` only for `confirmation_status = 'confirmed'` and `operation_status = 'waiting'`;
  `dropped_off` only from `boarded`.
- `private.close_confirmations` turns `pending` into `expired` at the deadline
  (`20260907235819_cycle_4_confirmations.sql`). `respond_trip` requires `private.can_view_student`
  (student profile or active guardian). Fleet-managed students have neither, so today they always
  expire and can never board.
- Fleet-managed students: `public.students.registration_origin = 'fleet_owner_created'`
  (`20260924002539_prd_9_fleet_managed_student_model.sql`). Passengers are inserted by
  `private.generate_trips` and reset to `pending` by `private.reconcile_enrollment_trips`
  (`20260926193538_fleet_transport_reconciliation.sql` ~L178).

### Red

`supabase/tests/database/058_fleet_managed_auto_confirmation.test.sql` (wrap in `begin; … rollback;`;
include `../_helpers.psql`, `../_planning.psql`, `../_operations.psql`, `../_fleet_transport.psql` as
needed — see `050_fleet_transport_commands.test.sql` and `056_*`/`025_generation.test.sql` for
fixture usage; `pg_temp.seed_fleet_transport()` creates fleet-managed minor + adult students in fleet
`41000000-0000-0000-0000-000000000001` with owner `40000000-0000-0000-0000-000000000001`). Assert:

1. A fleet-managed student (no `profile_id`, no active `student_guardians` row) allocated with
   `public.assign_fleet_student_transport` and materialized with `private.generate_trips` gets
   `confirmation_status = 'confirmed'`, `confirmation_at` not null, `confirmation_by` null.
2. A `guardian_created` student (the cycle-3 `minor` from `pg_temp.seed_cycle_3()` /
   `seed_cycle_4()`) stays `pending` after generation.
3. A fleet-managed student that has an **active** guardian row stays `pending` (insert a
   `student_guardians` row as `postgres` in the test).
4. After `private.close_confirmations(now)` past the deadline, the fleet-managed passenger is still
   `confirmed` (not `expired`).
5. Reinstatement path: updating the fleet-managed passenger to `confirmation_status = 'pending'`
   (simulating reconciliation) ends as `confirmed`.
6. Tenant isolation: a second fleet's (`41000000-…0002`, owner `40000000-…0005`) guardian-created
   passenger is unaffected (stays `pending`); every touched row keeps its own `fleet_id`.
7. As the assigned driver (`40000000-0000-0000-0000-000000000003`) after `start_trip`,
   `record_passenger_event(trip, fleet_student, 'boarded', cmd)` succeeds for the auto-confirmed
   passenger (end-to-end proof of the fix). If the fixture's trip cannot be started because the
   confirmation window is still open, generate with a `p_now`/schedule such that the deadline has
   passed, or call `private.close_confirmations` with a `p_now` after the deadline first.

Run (single file needs include expansion):

```bash
python3 - <<'EOF'
import sys, subprocess, tempfile
from pathlib import Path
sys.path.insert(0, 'supabase/tests')
from run_database_tests import expand_includes
src = Path('supabase/tests/database/058_fleet_managed_auto_confirmation.test.sql').resolve()
with tempfile.TemporaryDirectory() as d:
    out = Path(d) / src.name
    out.write_text(expand_includes(src))
    sys.exit(subprocess.run(['supabase', 'test', 'db', '--local', str(out)]).returncode)
EOF
```

Confirm cases 1, 4, 5, 7 fail for the right reason (`pending`/`expired`, `invalid_transition`).

### Green

`supabase migration new fleet_managed_auto_confirmation`:

```sql
-- Fleet-managed students have no guardian or student account that can answer
-- respond_trip, so the fleet confirms them by default (opt-out). Absence is
-- recorded at the stop. Students with an account keep the normal flow.
create function private.auto_confirm_fleet_managed_passenger()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.confirmation_status = 'pending' and exists (
    select 1
    from public.students s
    where s.id = new.student_id
      and s.registration_origin = 'fleet_owner_created'
      and s.profile_id is null
      and not exists (
        select 1 from public.student_guardians sg
        where sg.student_id = s.id and sg.status = 'active'
      )
  ) then
    new.confirmation_status := 'confirmed';
    new.confirmation_at := clock_timestamp();
    new.confirmation_by := null;
  end if;
  return new;
end;
$$;

revoke all on function private.auto_confirm_fleet_managed_passenger() from public, anon, authenticated;

create trigger trip_passengers_auto_confirm_fleet_managed
before insert or update of confirmation_status on public.trip_passengers
for each row execute function private.auto_confirm_fleet_managed_passenger();
```

Verify column/status names against the schema before applying (`\d public.student_guardians`). Then:
`supabase migration up --local`, rerun 058, then the full suite
`python3 supabase/tests/run_database_tests.py` (note: `043_auth_seed_compatibility` may already fail
on the shared local DB because of Auth state — that is pre-existing; report it, don't "fix" it) and
`supabase db lint --local --schema public,private --fail-on error`.

## 3. Flutter domain — commands, errors, next action (TDD)

### 3.1 Command ids

Reuse `createFleetCommandId()` from `vango_app/lib/features/fleet/models/fleet_command_id.dart`
(do not add a uuid package).

### 3.2 Error mapper — new file `vango_app/lib/features/driver/services/trip_command_error_mapper.dart`

Mirror `vango_app/lib/features/fleet/services/fleet_planning_error_mapper.dart`:

```dart
/// Definitive rejections drop the pending command id; uncertain outcomes keep it for retry.
enum TripCommandFailure { rejected, accessLost, uncertain }
```

`kind(Object error)` and `message(Object error)` keyed **only** by `PostgrestException.code` (never the
message text); `AuthException` → `accessLost`.

| code | kind | pt-BR message |
| --- | --- | --- |
| `confirmation_closed` | rejected | `Aguarde o encerramento das confirmações para iniciar a viagem.` |
| `invalid_transition` | rejected | `Esta ação não está disponível no estado atual da viagem.` |
| `passengers_on_board` | rejected | `Há alunos sem desembarque ou ausência registrados.` |
| `resource_in_use` | rejected | `A van ou o motorista já estão em outra viagem ativa.` |
| `idempotency_conflict` | rejected | `Este comando conflita com outro já registrado. Recarregue a viagem.` |
| `invalid_input` | rejected | `Não foi possível registrar a ação. Recarregue a viagem.` |
| `email_unverified` | rejected | `Confirme seu e-mail para operar viagens.` |
| `unauthenticated`, `forbidden`, `not_found`, `42501` | accessLost | `Você não tem acesso a esta viagem.` |
| anything else (incl. `SocketException`, `TimeoutException`, 5xx, `FormatException`) | uncertain | `Não foi possível confirmar a ação. Tente novamente.` |

Test file `vango_app/test/unit/features/driver/trip_command_error_mapper_test.dart`: every row above,
plus "message never contains the backend message text".

### 3.3 Model additions — `vango_app/lib/features/driver/models/driver_trip.dart`

Add (with `///` docs), tested in `vango_app/test/unit/features/driver/driver_trip_test.dart`
(reuse its `tripProjection(...)` helper; it accepts `passengers:` and `stops:` overrides):

- `bool get isOutbound` — true when the first `home` stop's `position` is lower than the first
  `school` stop's position (backend uses home 1000+ / school 100000+ for going and the reverse for
  return); true when there are no home stops.
- `RouteStop? get schoolStop` — first `StopKind.school` stop.
- `RouteStop? get nextActionStop`:
  - outbound: first `home` stop with `status == StopStatus.pending`; else the school stop if its
    status is not `reached`; else `null`.
  - return: the school stop if not `reached`; else first `home` stop with `status == boarded`;
    else `null`.
  - origin/destination are **never** action stops (they are not marked in the MVP).
- `bool get canFinish` — trip `active` and every `home` stop is `droppedOff` or `absent`.

Keep `nextPendingStop`, `pendingStops`, `mappableStops` unchanged (task 22 / location service use
them).

### 3.4 Service — `vango_app/lib/features/driver/services/driver_route_service.dart`

Replace the local `startTrip()`, `updateStopStatus(...)`, `finishTrip()` (search for the comment
"The lifecycle methods below are still local-only") with backend commands. Each sends the RPC, then
returns `await getTrip(tripId)` (fresh persisted state). Exact parameter names:

```dart
Future<DriverTrip> startTrip(String tripId, String commandId)
//   rpc('start_trip', {'p_trip_id': tripId, 'p_command_id': commandId})
Future<DriverTrip> recordPassengerEvent(String tripId, String studentId, PassengerEventKind kind, String commandId)
//   rpc('record_passenger_event', {'p_trip_id', 'p_student_id', 'p_kind': 'boarded'|'absent'|'dropped_off', 'p_command_id'})
Future<DriverTrip> markStopReached(String tripId, String stopId, String commandId)
//   rpc('mark_trip_stop_reached', {'p_stop_id': stopId, 'p_command_id': commandId})  (returns void)
Future<DriverTrip> finishTrip(String tripId, String commandId)
//   rpc('finish_trip', {'p_trip_id': tripId, 'p_cancel': false, 'p_reason': null, 'p_command_id': commandId})
```

`enum PassengerEventKind { boarded, absent, droppedOff }` with the backend string mapping (put it in
`route_stop.dart` or the service file). Errors propagate unchanged (the screen maps them). No local
`copyWith` mutation of status anywhere.

Tests in `vango_app/test/unit/features/driver/driver_route_service_test.dart` (reuse the existing
`planningClient` + `jsonResponse` helpers; route by `request.url.path`): exact JSON bodies for all
four RPCs; each success performs a follow-up `get_trip` and returns its state; a backend error
(e.g. 409 `{"code":"passengers_on_board","message":"x"}`) propagates as `PostgrestException` with that
code and **no** `get_trip` reload is required by the service; remove the old local-lifecycle test.

### 3.5 Pending command registry — new `vango_app/lib/features/driver/models/trip_command_ledger.dart`

Small pure class (unit-tested in `trip_command_ledger_test.dart`):

```dart
/// Remembers command ids of logical actions whose outcome is unknown so a retry reuses them.
class TripCommandLedger {
  /// Returns the pending id for [actionKey] or creates (and remembers) a new one.
  String idFor(String actionKey);
  /// Forgets [actionKey] after a definitive outcome (success or rejection).
  void resolve(String actionKey);
  bool isPending(String actionKey);
}
```

Action keys: `start`, `finish`, `passenger:<studentId>:<kind>`, `stop:<stopId>`. Composite actions use
one key per sub-command (`stop:<schoolStopId>` plus one `passenger:<id>:<kind>` per student) so a
partial failure retries only what is unresolved and already-accepted sub-commands are idempotent on the
backend (same command id → stored result). Inject an id factory for tests
(`TripCommandLedger({String Function()? newId})`, default `createFleetCommandId`).

## 4. Screen and panel (TDD, widget tests)

Files: `vango_app/lib/features/driver/screens/driver_route_screen.dart`,
`vango_app/lib/features/driver/widgets/driver_active_trip_panel.dart`.
Tests: `vango_app/test/widget/features/driver/driver_route_screen_test.dart` (extend its
`pumpRouteScreen` helper so the fake backend routes by RPC path and can return a sequence of
projections/errors; `testId` from `fleet_planning_service_test.dart` is the signed-in user, so use
`tripProjection(driverUserId: testId, ...)` for operable trips).

Screen state adds `final _ledger = TripCommandLedger();` and `bool _isSubmitting` (disable action
buttons while a command is in flight; no double submit).

One private runner used by every handler:

```dart
/// Runs one logical action; [steps] are (actionKey, command) pairs executed in order.
Future<void> _runCommands(List<(String, Future<DriverTrip> Function(String commandId))> steps,
    {required String successMessage})
```

Behavior: for each step, `id = _ledger.idFor(key)`; await the command; on success `_ledger.resolve(key)`
and keep the returned trip. On error: `TripCommandErrorMapper.kind(e)`:
- `rejected`/`accessLost` → `_ledger.resolve(key)` for that step, stop, reload `getTrip` (best effort),
  show the mapped message (SnackBar, `AppColors.errorRed`).
- `uncertain` → keep the key pending, stop, reload `getTrip`; if the reload shows the step applied
  (see "applied" checks below) resolve the key; show the uncertain message with a SnackBar action
  `Tentar novamente` that re-invokes the same handler (which reuses pending ids).
Only after **all** steps succeed: `setState(_trip = latest)` and show `successMessage`
(`AppColors.successGreen`). Never `setState` a locally mutated trip.

"Applied" checks after reload: `start` → status `active`; `finish` → `completed`;
`passenger:<id>:boarded|absent|dropped_off` → that home stop has the matching status;
`stop:<id>` → that stop's status `reached`.

Handlers (replace the bodies of the existing ones; keep their names):

- `_handleStartTrip` → one step `('start', (id) => svc.startTrip(trip.id, id))`; success message
  `Viagem iniciada.`; **only after success** call the existing
  `_locationService.startTracking(routePoints: ..., pendingStops: ..., mode: _selectedTrackingMode)`
  exactly as today (task 22 will rework it). Show the existing start button only when
  `trip.isOperableBy(currentUserId)` and status is `scheduled`/`confirmationClosed` (already true from
  task 20).
- `_handleBoardStop(stop)` → `passenger:<studentId>:boarded`, message `Embarque de <nome> registrado.`
- `_handleMarkAbsent(stop)` → `passenger:<studentId>:absent`, message `<nome> marcado como ausente.`
- new `_handleDropOff(stop)` (return direction home stop) → `passenger:<studentId>:dropped_off`,
  message `Desembarque de <nome> registrado.`
- new `_handleSchoolArrival()` (outbound) → steps `stop:<schoolId>` then one
  `passenger:<id>:dropped_off` per home stop with status `boarded`; message
  `Chegada na escola registrada.`
- new `_handleSchoolBoarding()` (return) → steps `stop:<schoolId>` then one `passenger:<id>:boarded`
  per home stop with status `pending`; message `Embarque na escola registrado.`
- `_handleFinishTrip` → step `finish`; **only after success** call `_locationService.stopTracking()`
  (today it is called before the RPC — move it); message `Viagem finalizada.`
  `passengers_on_board` shows the mapped message and keeps the trip active (tracking keeps running).

Panel (`DriverActiveTripPanel`) — drive it by `trip.nextActionStop` / `trip.isOutbound` /
`trip.canFinish` instead of `nextPendingStop`:

| situation | buttons (pt-BR) | callback |
| --- | --- | --- |
| outbound, next action = home stop | `Confirmar Embarque`, `Ausente` | board / absent |
| outbound, next action = school | `Confirmar chegada na escola` | school arrival |
| return, next action = school | `Embarcar presentes` (+ per-student `Ausente` in the stop list for `pending` home stops while the school is not reached) | school boarding / absent |
| return, next action = home stop | `Desembarcou` | drop off |
| `canFinish` | `Finalizar viagem` | finish |
| none of the above (unexpected) | text `Aguardando atualização da viagem.` | — |

Add constructor callbacks `onDropOff`, `onSchoolArrival`, `onSchoolBoarding`, and `bool isBusy`
(disables buttons). Update the proximity banner action (`_handleBoardStop(_approachingStop!)`) to
only show for outbound home stops that are `pending`.

### Widget test cases (all must exist)

1. Start success: tap `Começar Percurso` → `start_trip` body has a UUID `p_command_id`; screen shows
   the active panel only after the follow-up `get_trip` returns `active`; snackbar `Viagem iniciada.`
2. Start rejected `confirmation_closed` (409) → message shown, still not active, a second tap sends a
   **new** command id.
3. Start uncertain (500 / thrown exception) → retry sends the **same** command id; if the reload
   already returns `active`, no retry is needed and the panel is active.
4. Board (outbound) persists via `record_passenger_event` `boarded` and the stop shows `Embarcou`
   only after reload.
5. Absent persists `absent`.
6. School arrival sends `mark_trip_stop_reached` then `dropped_off` for each boarded student, in
   that order; partial uncertain failure on the second student retries only the unresolved
   sub-commands with their original ids.
7. Return direction: `Embarcar presentes` boards every pending student; home stop `Desembarcou`
   sends `dropped_off`.
8. Finish blocked: `passengers_on_board` (409) → message `Há alunos sem desembarque ou ausência
   registrados.`, trip stays active, `stopTracking` not called (use a fake
   `DriverLocationService` subclass that counts calls; pass it via `locationService:`).
9. Finish success → `completed` banner after reload, `stopTracking` called once after the RPC.
10. Buttons are disabled while a command is in flight (no duplicate RPC on double tap).
11. Reopening the screen (fresh pump) with a projection where the passenger is `boarded` shows the
    persisted state (restart survival).
12. Access lost (`not_found` 404 on a command) → `Você não tem acesso a esta viagem.`

## 5. Gates (record actual output in the final report)

```bash
# root of ../vango-be-task-21
python3 supabase/tests/run_database_tests.py
supabase db lint --local --schema public,private --fail-on error
cd vango_app
dart format --output=none --set-exit-if-changed <every file you touched>
flutter analyze            # must be 0 issues
flutter test --coverage    # all green; driver models/services ≥ 80% line coverage
cd .. && git diff --check && git status
```

Update `vango_app/README.md` (Driver section): replace the "Pending (Task #21)" bullet with what is now
persisted, the fleet-managed opt-out confirmation, the outbound/return action flow, and retry
semantics. Do not edit root `README.md` or `deliverables.md` (task 19 is editing them).

## 6. Acceptance criteria (issue #21)

- [ ] Trip lifecycle is persisted in Supabase (start, boarded, absent, dropped_off, school reached, finish).
- [ ] Passenger states survive restart.
- [ ] No local mutation is presented as authoritative before backend success.
- [ ] Retry semantics preserve idempotency (same id on uncertain retry; new id for new actions).
- [ ] Backend transition errors are visible to the user (mapped pt-BR messages, no raw text).
- [ ] Fleet-managed students can be operated without guardian confirmation (pgTAP 058).

## 7. Out of scope

GPS/telemetry and the tracking-mode toggle (task 22), trip cancellation, incidents, owner override
UI, notifications, root docs, `db push`.
