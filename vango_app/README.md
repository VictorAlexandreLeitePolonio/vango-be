# VanGo Flutter App

The VanGo mobile client for school and university transport logistics. Built with Flutter, Supabase, and Mapbox.

---

## 1. Features Implemented

### 🚐 Driver Route & Live Van Telemetry
- **Mapbox Vector Map & Routing:** High-resolution map tiles with traffic polyline rendering powered by Mapbox Directions API.
- **Dual Location Tracking Modes (`DriverLocationService`):**
  - **GPS Real (`geolocator`):** Reads native hardware GPS sensors on mobile devices with foreground service support.
  - **Virtual Simulation:** Smoothly traverses the polyline at ~35 km/h with live calculation of speed, progress, and bearing. Allows end-to-end testing on web, emulators, and desktop.
- **Azimuth & Heading Calculation:** Van marker dynamically rotates via spherical trigonometry (`atan2`) to point in the exact travel direction of the road.
- **Intelligent Proximity Detection:** Calculates geodesic Haversine distance in real time. When the vehicle is within 50 meters of a student's pickup point, a floating banner alerts the driver with a quick action to register boarding.
- **Trip Lifecycle:** Complete trip controls (Start Trip, Board Student, Mark Absent, Finish Trip at school).

### 🎓 Student / Guardian Marketplace & Registration
- **Mapbox Address Autocomplete (`MapboxAddressAutocompleteField`):** Debounced real-time place search suggestions with coordinate extraction for precise student pickup and school locations.
- **Dependent / Student Registration:** Registration of minor students with home address, target school, period (morning/afternoon), and transport direction (going/return).
- **Vans Marketplace (`VansMarketplaceScreen`):** Search and discovery of published fleet vans with capacity, license plate, school coverage, and one-tap request submission (`submit_fleet_join_request`).

### 🏢 Fleet Owner Dashboard (`FleetOwnerDashboardScreen`)
- Multi-fleet switcher with live statistics (vans, active students, pending requests).
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
5. Log in as a driver (`carlos.motorista@vango.com.br` / `Senha@123`), open the route, tap **"Iniciar Viagem"**, and grant location permission.

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