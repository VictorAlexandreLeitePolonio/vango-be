# VanGo Flutter App

The VanGo mobile client for school and university transport logistics. Built with Flutter, Supabase, and Mapbox.

---

## 1. Features Implemented

### 🚐 Driver Route & Live Van Telemetry
- **Persisted service-day trips (Task #20):** "Minhas viagens" lists today's trips of every fleet where the user is `owner` or `driver` through `list_service_day`; the route screen receives a trip id and loads it through `get_trip`. Owners see every fleet trip read-only ("Ver viagem"); only the assigned driver (`driver_user_id`) gets "Iniciar viagem" / "Continuar viagem". Empty days and backend failures render real empty and retry states — there is no synthetic or fallback trip.
- **Backend labels:** route name, van plate and passenger names come from the owner/driver `get_trip` projection (migration `20261003113739_extend_trip_projection_labels.sql`); stops keep the backend `position` order. Trips only exist after the daily operations job materializes them (Task #19).
- **Persisted trip lifecycle (Task #21):** start, boarded, absent, dropped_off, school-reached and finish are persisted in Supabase through the idempotent `start_trip` / `record_passenger_event` / `mark_trip_stop_reached` / `finish_trip` RPCs; nothing is presented as done before the backend accepts it, and every successful command reloads `get_trip` so reopening the screen restores the real state.
- **Fleet-managed opt-out confirmation:** fleet-owner-created students with no account and no active guardian are auto-confirmed by a backend trigger (pgTAP `058`); students with an account keep the normal confirm/expire flow.
- **Outbound/return action flow:** outbound marks home stops "Embarcou"/"Ausente", then "Confirmar chegada na escola" drops off every boarded student before finishing; return starts at the school ("Embarcar presentes" boards waiting students, with per-student "Ausente" while the school is not reached), then each home stop marks "Desembarcou" before finishing.
- **Retry semantics:** a definitive backend rejection drops the pending command id and shows a mapped pt-BR message; an uncertain outcome (timeout/5xx/unknown) reloads `get_trip` — if the action already applied, the pending id is dropped, otherwise the snackbar offers "Tentar novamente", which reuses the SAME command id. New user actions always mint a new command id.
- **Mapbox Vector Map & Routing:** High-resolution map tiles with traffic polyline rendering powered by Mapbox Directions API.
- **Real GPS telemetry (Task #22):** while a trip is `active` and the signed-in user holds its open assignment, `DriverLocationService` reads the device GPS and `TripTelemetryUploader` sends live batches to `ingest_trip_locations` (every 5 s or 20 points; `sequence` = ms since `trip.started_at`; points older than 25 s are dropped because the backend rejects live points older than 30 s; rate-limit/network failures are retried, a refused trip stops uploads). Tracking also resumes when an active trip is reopened and stops when it completes. There is no offline buffer yet.
  - **No silent fallback:** a disabled service, denied permission or sensor error shows `GPS inativo: <motivo>` with **"Ativar GPS"**; the trip stays operable and nothing is uploaded. The pill shows `GPS Ativo` only after real fixes arrive.
  - **Demo simulation (opt-in):** only builds with `--dart-define=VANGO_ALLOW_SIMULATION=true` show the **"Alternar"** toggle; simulated samples are labeled `Simulação (demo)` and are never uploaded.
  - **Privacy:** location coordinates, Mapbox request URLs and response bodies are never logged.
- **Azimuth & Heading Calculation:** Van marker dynamically rotates via spherical trigonometry (`atan2`) to point in the exact travel direction of the road.
- **Intelligent Proximity Detection:** Calculates geodesic Haversine distance in real time. When the vehicle is within 50 meters of a student's pickup point, a floating banner alerts the driver with a quick action to register boarding.

### 🎓 Student / Guardian Marketplace & Registration
- **Mapbox Address Autocomplete (`MapboxAddressAutocompleteField`):** Debounced real-time place search suggestions with coordinate extraction for precise student pickup and school locations.
- **Dependent / Student Registration:** Registration of minor students with home address, target school, period (morning/afternoon), and transport direction (going/return).
- **Vans Marketplace (`VansMarketplaceScreen`):** Search and discovery of published fleet vans with capacity, license plate, school coverage, and one-tap request submission (`submit_fleet_join_request`). Vans are listed once per school served by their fleet (`fleet_service_schools`).
- **No demo fallbacks:** `StudentService` only returns backend data. Empty results render empty states; backend failures propagate as `PostgrestException` and are shown as pt-BR messages via `StudentErrorMapper` (raw errors are never shown or logged). Tests inject a `StudentDataSource` fake (`test/support/fake_student_data_source.dart`).

### 🏢 Fleet Owner Dashboard (`FleetOwnerDashboardScreen`)
- After authentication, owner fleet choices come from the current `get_my_access_context` result. One owner fleet opens directly; multiple owner fleets require an explicit selection by fleet ID; no owner fleet shows an access message.
- The dashboard route requires a fleet ID and opening user ID, then rechecks the current session and owner membership before reading data. The user ID detects session changes and is not an authorization credential.
- Pending requests, drivers, and enrolled students display real empty or retry states. No local sample records are used on the authenticated owner path.
- The enrolled-student list requires the owner-scoped `list_fleet_students` RPC from Task #10. Apply that migration before using the dashboard with backend data.
- Review and approve/reject pending student join requests via `decide_fleet_join_request`.

---

## 2. Configuration (`.env`)

Runtime configuration is provided through Dart environment defines in `vango_app/.env`:

```env
SUPABASE_URL=http://127.0.0.1:54321
SUPABASE_PUBLISHABLE_KEY=your_supabase_anon_key
MAPBOX_ACCESS_TOKEN=your_mapbox_public_token
```

> **Security Note:** Only the Supabase anon/publishable key and Mapbox public token belong in the client. Never place the backend `service_role` key in this file. The `.env` file is git-ignored.

---

## 3. Running the App

### Option A: Run on a Physical Android Device (Real GPS)
1. Enable **USB Debugging** in your Android device's Developer Options.
2. Connect your smartphone via USB cable.
3. Verify device connection:
   ```bash
   flutter devices
   ```
4. Launch the application:
   ```bash
   flutter run -d <device_id> --dart-define-from-file=.env
   ```
5. Log in as the trip's assigned driver, open a trip from **"Minhas viagens"**, tap **"Começar Percurso"**, and grant location permission. The list is empty until the backend has materialized trips for today.

### Option B: Run on Desktop or Web (Virtual Simulation Mode)
1. Run on Windows desktop:
   ```bash
   flutter run -d windows --dart-define-from-file=.env
   ```
   Or in your web browser:
   ```bash
   flutter run -d edge --dart-define-from-file=.env
   ```
   Add `--dart-define=VANGO_ALLOW_SIMULATION=true` to enable the demo simulation:
   ```bash
   flutter run -d edge --dart-define-from-file=.env --dart-define=VANGO_ALLOW_SIMULATION=true
   ```
2. In the driver screen, tap **"Alternar"** to select `Simulação (demo)` before starting; it steps through the route coordinates and never sends telemetry.

---

## 4. Permissions (Android & iOS)

### Android (`android/app/src/main/AndroidManifest.xml`)
- `ACCESS_FINE_LOCATION`
- `ACCESS_COARSE_LOCATION`
- `FOREGROUND_SERVICE`
- `FOREGROUND_SERVICE_LOCATION`

### iOS (`ios/Runner/Info.plist`)
- `NSLocationWhenInUseUsageDescription` (pt-BR prompt shown when the driver starts tracking)

---

## 5. Automated Tests & Code Quality

```bash
# Code format check
dart format --output=none --set-exit-if-changed .

# Static analysis (zero issues allowed)
flutter analyze

# Run full test suite
flutter test

# Run tests with coverage
flutter test --coverage
```

## Owner planning (#17)

The fleet dashboard now opens independent coverage, vehicle, route and schedule
forms. Commands use immutable UUIDs and edit revisions; uncertain writes retry
the captured command, and post-commit refresh failures only retry reads. Map
endpoints require explicit confirmation. Institutions require published evidence
and validated coordinates; statewide real catalog acquisition remains separate.
See the repository README's **Owner fleet planning (#17)** section for the exact
RPC additions, publication prerequisite, local HTTP/native integration commands
and release boundaries. No new runtime dependency or environment key is required.
