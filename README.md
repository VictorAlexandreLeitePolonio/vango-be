# VanGo Backend

Backend for VanGo, a mobile Flutter application for managing school and university transport logistics. The MVP uses Supabase as a complete backend, without requiring a custom Node.js server.

## Repository Status

The project features a reproducible local Supabase environment with Cycles 1 and 2 implemented locally. The educational institutions catalog remains empty by scope decision; map and operational domains remain scheduled for subsequent cycles.

Cycle 2 delivers database schemas, RLS policies, public search capabilities, and RPC functions for students, guardians, join requests, invitations, and active links. No automated importer, external integrations, real school loading, email dispatch, or Flutter UI code is included in Cycle 2.

## MVP Objective

VanGo connects fleet owners, drivers, guardians, and adult students. The platform enables fleet discovery, linkage requests, van and route organization, trip confirmations, live van tracking during active trips, and operational notifications.

Payments, tuition billing, legal contracts, driver commissions, and ratings/reviews are explicitly out of scope for the MVP.

## Profiles and Roles

A single user account can accumulate multiple roles. Roles are contextual to a fleet, which acts as the tenant:

- `owner`: Administers only the fleets where they are listed as an owner;
- `driver`: Operates only assigned vans and trips;
- `guardian`: Manages linked minor students under their account;
- `student`: Represents an authenticated adult student.

Minor students do not have user logins. They are dependents managed by one or more guardians. A primary guardian manages student details and secondary guardians; secondary guardians follow and confirm daily trips.

The same user can be an owner in Fleet A, a driver in Fleet B, and a guardian for a student. The backend always validates roles strictly within the provided `fleet_id`.

## Approved Architecture

The backend combines native Supabase features:

- **Supabase Auth:** Email/password sign-up, email confirmation, and password recovery;
- **PostgreSQL:** Relational data storage, integrity constraints, transactions, and audit logs;
- **Row Level Security (RLS):** Fleet multi-tenant isolation and personal data privacy;
- **Database Functions/RPC:** Transactional operations and critical domain business logic;
- **Realtime Broadcast:** Live van location tracking via private per-trip channels;
- **Edge Functions:** Route optimization, geocoding, push notifications, and third-party integrations;
- **Storage:** Avatars, fleet logos, and future attachments;
- **Cron Jobs:** Daily trip generation, confirmation lockouts, and raw GPS retention cleanup.

Flutter applications can query and modify simple RLS-protected tables. Domain actions — such as approving an enrollment link, reserving a seat, swapping drivers, or initiating a trip — must execute via RPC functions. External integrations and API secrets reside strictly inside Edge Functions.

## Core Workflows

### Marketplace and Linking

Published fleets appear based on served cities and covered institutions. Public search utilizes `search_schools` and `search_marketplace`; only sanitized institutional and commercial details are returned.

Primary guardians create minor student profiles, while adult students create their own records. Link requests store a private snapshot of the residential address, require an active/covered school and served city, and await owner approval. Approval establishes the enrollment link within the same transaction.

Owners can also invite guardians or adult students. Flutter retains the token during sign-up/login callbacks; the backend stores only the SHA-256 hash and accepts invitations only for matching confirmed emails. Secondary guardians receive derived access to the dependent's active links.

The `schools` catalog contains no real data in this cycle. Future regional imports will be seeded directly in Supabase without a dedicated importer script or public API.

### Fleet and Routes

The fleet owner registers vans, defines seating capacity, configures routes, and assigns default drivers and vehicles. Temporary substitutions can be made for specific trips without altering regular schedule templates.

Each `route` represents a single direction: pickup (to school) or drop-off (from school). Opposite routes can form a paired set. A route contains schools ordered via a junction table; the owner specifies school sequence. The system optimizes residential stops respecting this school sequence and target schedules.

Schools originate from an empty global catalog in this cycle. Users cannot write directly to the catalog; future data loads will be performed manually in Supabase. External data sources, if required, will be decided prior to importing.

### Schedules, Trips, and Confirmations

A route maintains a weekly schedule. Each student can participate on custom days and directions (e.g., opting out of morning pickup while using afternoon drop-off).

The system generates the next day's trips from weekly schedules. `service_days` groups morning pickup and afternoon drop-off trips for the same operational day. Each `trip` executes a single `route` and maintains its own status, timestamps, van, driver, passenger manifest, and history.

Expected passengers start with pending confirmation. The confirmation cutoff deadline is configurable per route, defaulting to 30 minutes before departure:

- `confirmed`: Included in route optimization;
- `declined`: Excluded from the route while remaining in trip history;
- `expired`: Unresponsive at cutoff time and excluded from the route.

Vehicle capacity evaluates regular schedule commitments, not daily absences. A van with 30 seats and 30 scheduled students displays as full; new link requests enter a waitlist.

### Driver Operations

Drivers access only assigned vans, trips, and passenger manifests. Drivers cannot alter addresses, school configurations, student profiles, or permanent route templates.

During a trip, drivers can:

- Start, complete, or cancel authorized trip operations;
- Select the next authorized school or stop point;
- Update passenger statuses to waiting, boarded, dropped-off, or absent;
- Log delays, traffic jams, accidents, mechanical failures, detours, or other operational incidents;
- Report temporary route detours with justification;
- Send categorized messages to trip participants.

State changes record exact timestamps and location coordinates. QR code scanning and automated boarding detection are out of scope for the MVP.

### Tracking and Privacy

Location tracking starts when the driver initiates a `trip` and ends upon trip completion or cancellation. Fleet owners can monitor all active trips across their fleet.

Guardians and adult students monitor only trips in which their linked student is confirmed. They receive live van coordinates, current school stop, ETA, their specific stop point, and an approximate public route geometry. The backend NEVER returns private residential addresses, student identities, stop points of other passengers, or full geometries that could expose another student's home location.

Raw GPS coordinates are retained for 30 days. Trip summaries, distance, duration, timetables, delays, incidents, boarding/drop-off records, and audit logs are retained indefinitely.

### Route Optimization

Base routes are recalculated whenever students, home addresses, schools, or assignments change. Daily trip creation does not call the external routing provider. Upon confirmation cutoff, the service recalculates routes only if the confirmed passenger manifest changes. Exceptional incidents can trigger emergency recalculations.

The MVP supports up to 30 students per van, plus departure points and school stops. Routing provider evaluation must assess stop limits, regional coverage, ETA accuracy, and cost. If an API request exceeds maximum waypoint limits, the service will split the calculation without altering domain models.

### Notifications

The system dispatches automated notifications for:

- Pending confirmation availability and upcoming deadlines;
- Trip initiation;
- Van approaching ~10 minutes from student stop;
- Arrival at student stop;
- Student boarding and drop-off;
- Arrival at school;
- Delays, detours, trip cancellations, and operational incidents;
- Manual messages sent by fleet owners.

Proximity alerts utilize live ETA rather than static radial distance. The default threshold is 10 minutes (configurable per route), with deduplication logic to prevent redundant alerts.

Fleet owners can broadcast messages across the entire fleet, specific routes, trips, vans, or individual users. Drivers select pre-defined incident categories with optional notes exclusively within their active trip context.

## Multi-tenancy and Security

The fleet acts as the tenant. Every operational entity includes a `fleet_id`, and every exposed table enforces Row Level Security (RLS). Possessing a UUID never grants unauthorized access.

Core Rules:

- Applications use only the public Supabase anon key;
- Secret keys remain stored in secure internal backend services;
- Client-provided roles are never trusted;
- Critical operations validate membership, roles, and state at the database level;
- No operation can remove or demote the last active owner of a fleet;
- Realtime channels are private and authorized strictly per trip;
- Audit logs are immutable for standard users;
- Public API projections omit personal and operational details.

## Planned Cycles

1. **Multi-tenant Foundation:** Local Supabase environment, Auth, profiles, fleets, memberships, multi-role support, RLS policies, and auditing — completed locally in Cycle 1.
2. **Marketplace and Linkings:** Empty school catalog, commercial coverage, student profiles, guardians, join requests, invitations, active links, privacy rules, and auditing — completed locally in Cycle 2. Preferences, vehicle capacity checks, and waitlist logic deferred.
3. **Fleet and Planning:** Vans, capacity management, driver management, routes, ordered school stops, weekly schedules, and assignments.
4. **Daily Operations:** Service days, trip generation, confirmations, driver/van substitutions, and attendance tracking.
5. **Tracking and Incidents:** Private Realtime tracking, GPS processing, privacy-safe visibility, detours, delays, and data retention policies.
6. **Route Optimization and Notifications:** Route optimization, ETA calculations, geocoding, push notifications, and external API integrations.

Each cycle features its own technical specification and implementation plan. Implementation strictly follows Test-Driven Development (TDD).

## Documentation Links

- [Technical Plan and Domain Model](./be-tech-plan.md)
- [Development Guidelines](./CONTRIBUTING.md)
- [Deliverables Log](./deliverables.md)
- [Cycle 1 Implementation Plan](./docs/superpowers/plans/2026-09-05-ciclo-1-fundacao-multitenant.md)
- [Cycle 2 Specification](./docs/superpowers/specs/2026-09-06-ciclo-2-marketplace-vinculos-design.md)
- [Cycle 2 Implementation Plan](./docs/superpowers/plans/2026-09-06-ciclo-2-marketplace-vinculos.md)
