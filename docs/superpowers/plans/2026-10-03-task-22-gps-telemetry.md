# Task 22 — Persist real driver GPS telemetry (plan)

GitHub: issue #22 (parent epic #15). Binding rules: `AGENTS.md`, `CONTRIBUTING.md`.

## Workspace

Worktree `/Users/victorpolonio/Desktop/vango-be-task-20`, branch `claude/task-22-gps-telemetry`
(from `d4c7088`, task 20). Task 21 runs in parallel in `../vango-be-task-21`; after it lands, rebase
this branch onto `claude/task-21-trip-lifecycle` and resolve `driver_route_screen.dart` conflicts.
Ownership: this task owns `driver_location_service.dart`, the new uploader, `mapbox_*` logging, the
tracking-mode toggle/pill and the GPS banner; task 21 owns lifecycle handlers and the active panel.

## Decisions made with the user

1. Upload only for an `active` trip whose current assignment belongs to the signed-in driver.
2. `sequence = capturedAt − trip.startedAt` in milliseconds (deterministic, restart-safe, int32 ≈ 24 days).
3. Flush every 5 s or at 20 points, `p_live = true`; drop points older than 25 s at flush time (backend
   rejects > 30 s live and the whole batch fails); transient failures re-queue (still age-filtered);
   no offline buffer (sprint #33).
4. Simulation exists only with `--dart-define=VANGO_ALLOW_SIMULATION=true`, labeled
   `Simulação (demo)`, and never uploads. Default mode is real GPS.
5. GPS failure during an active trip does not block operation: banner `GPS inativo: <motivo>` with
   `Ativar GPS`; the pill never says `GPS Ativo` unless real fixes are arriving; nothing is uploaded.

## Backend facts (`ingest_trip_locations`, `20260907235840_cycle_6_locations.sql`)

- Signature `(p_trip_id uuid, p_assignment_id uuid, p_points jsonb, p_live boolean) returns jsonb`.
- 1–200 points; each `{sequence int > 0, captured_at timestamptz, latitude, longitude, accuracy 0..10000,
  speed ≥ 0 | null, heading [0,360) | null}`; unique sequences per batch.
- Live: trip `active`, assignment open and owned by the caller (`not_found` otherwise); captured_at ≥
  `started_at`, ≤ now + 2 min, ≥ now − 30 s; one bad point fails the batch (`invalid_input`).
- Same `(assignment, sequence)` with a different payload → `idempotency_conflict`; identical → duplicate (ok).
- New live points within 1 s of the last received → `rate_limited` (429).

## Steps (TDD)

1. **Model** (`driver_trip.dart`): parse `trip.started_at` → `startedAt`, and `assignments[]` →
   `currentAssignmentIdFor(userId)` (open assignment `valid_until == null` with `driver_user_id ==
   userId`). Tests in `driver_trip_test.dart`.
2. **Telemetry sample**: extend `VanTelemetryUpdate` with `capturedAt`, `accuracyMeters`,
   `isSimulated`. GPS fills them from `Position`; simulation sets `isSimulated: true`.
3. **Uploader** (new `trip_telemetry_uploader.dart`): `start(tripId, assignmentId, startedAt)`,
   `add(sample)`, `stop()`, injectable clock and timer duration, `ValueListenable<TelemetrySyncState>`
   (`idle`, `syncing`, `synced`, `failing`, `rejected`). Rules: ignore simulated samples and samples
   before `startedAt`; sequence per decision 2; heading normalized to `[0,360)`, negative/NaN speed or
   heading → null; flush rules per decision 3; `rate_limited`/network/5xx → re-queue + `failing`;
   `invalid_transition`/`not_found`/`forbidden` → stop + `rejected`; `idempotency_conflict` → drop
   batch. `stop()` discards the queue (live points after completion would be rejected).
   Tests: payload mapping (exact JSON), sequence determinism across two uploader instances, batching
   by count and by timer, age drop, re-queue on 500/429, stop on rejection, simulated ignored,
   stop cancels timer.
4. **Location service**: `startTracking` no longer falls back to simulation. Permission/service
   result is returned as `GpsAvailability` (`available`, `serviceDisabled`, `denied`,
   `deniedForever`, `error`); stream errors emit `error`. Simulation can start only when
   `allowSimulation` (from `bool.fromEnvironment('VANGO_ALLOW_SIMULATION')`, injectable) is true.
   Default mode `deviceGps`. Remove every `debugPrint` that can carry coordinates or errors with
   coordinates. Tests: denied → no simulation started, availability `denied`; simulation refused when
   not allowed; simulation emits `isSimulated` samples when allowed.
5. **Privacy**: drop the coordinate-bearing URL/body logs in `mapbox_directions_service.dart`
   (L72, L120); keep status-only logs.
6. **Screen**: start tracking + uploader when the loaded/started trip is `active` (also on reopen),
   with assignment from `currentAssignmentIdFor(currentUserId)`; stop both on completion, on
   `rejected`, and in `dispose`. Pill: `GPS Ativo` only while real fixes arrive and sync is not
   `rejected`; `Simulação (demo)` when simulated; toggle hidden unless simulation is allowed. Banner
   `GPS inativo: <motivo>` (pt-BR: serviço desativado / permissão negada / permissão negada
   permanentemente / erro no GPS) with `Ativar GPS`. Widget tests: denied permission shows banner
   and never `GPS Ativo`; toggle hidden by default; active trip on open starts tracking; completed trip
   stops it.
7. **Gates & docs**: analyze 0, touched files formatted, `flutter test --coverage` (≥ 80% on
   uploader/location/model), `git diff --check`; `vango_app/README.md` documents real GPS upload,
   `VANGO_ALLOW_SIMULATION`, and permissions.

## Acceptance criteria (issue #22)

- [ ] Real mobile GPS reaches `ingest_trip_locations` for an authorized active trip.
- [ ] Failed permission never displays "GPS active".
- [ ] No silent simulation fallback remains.
- [ ] Sensitive telemetry is not logged.
- [ ] Tracking stops when the trip completes.
- [ ] Tests and analysis pass.
