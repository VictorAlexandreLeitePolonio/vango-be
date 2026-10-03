# VanGo Flutter App

The VanGo mobile client for school and university transport logistics. Built with Flutter, Supabase, and Mapbox.

---

## 1. Features Implemented

### 🚐 Driver Route & Live Van Telemetry
- **Persisted service-day trips (Task #20):** "Minhas viagens" lists today's trips of every fleet where the user is `owner` or `driver` through `list_service_day`; the route screen receives a trip id and loads it through `get_trip`. Owners see every fleet trip read-only ("Ver viagem"); only the assigned driver (`driver_user_id`) gets "Iniciar viagem" / "Continuar viagem". Empty days and backend failures render real empty and retry states — there is no synthetic or fallback trip.
- **Backend labels:** route name, van plate and passenger names come from the owner/driver `get_trip` projection (migration `20261003113739_extend_trip_projection_labels.sql`); stops keep the backend `position` order. Trips only exist after the daily operations job materializes them (Task #19).
- **Pending (Task #21):** start, boarding/absence and finish still update the screen locally; they are not yet persisted through `start_trip` / `record_passenger_event` / `finish_trip`.
- **Mapbox Vector Map & Routing:** High-resolution map tiles with traffic polyline rendering powered by Mapbox Directions API.
- **Dual Location Tracking Modes (`DriverLocationService`):**
  - **GPS Real (`geolocator`):** Reads native hardware GPS sensors on mobile devices with foreground service support.
  - **Virtual Simulation:** Smoothly traverses the polyline at ~35 km/h with live calculation of speed, progress, and bearing. Allows end-to-end testing on web, emulators, and desktop.
- **Azimuth & Heading Calculation:** Van marker dynamically rotates via spherical trigonometry (`atan2`) to point in the exact travel direction of the road.
- **Intelligent Proximity Detection:** Calculates geodesic Haversine distance in real time. When the vehicle is within 50 meters of a student's pickup point, a floating banner alerts the driver with a quick action to register boarding.

### 🎓 Student / Guardian Marketplace & Registration
- **Mapbox Address Autocomplete (`MapboxAddressAutocompleteField`):** Debounced real-time place search suggestions with coordinate extraction for precise student pickup and school locations.
- **Dependent / Student Registration:** Registration of minor students with home address, target school, period (morning/afternoon), and transport direction (going/return).
- **Vans Marketplace (`VansMarketplaceScreen`):** Search and discovery of published fleet vans with capacity, license plate, school coverage, and one-tap request submission (`submit_fleet_join_request`).

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
2. In the driver screen, the virtual simulation mode will step through the route coordinates automatically.

---

## 4. Permissions (Android & iOS)

### Android (`android/app/src/main/AndroidManifest.xml`)
- `ACCESS_FINE_LOCATION`
- `ACCESS_COARSE_LOCATION`
- `FOREGROUND_SERVICE`
- `FOREGROUND_SERVICE_LOCATION`

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
