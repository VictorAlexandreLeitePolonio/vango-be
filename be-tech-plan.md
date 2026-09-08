# VanGo — Backend Technical Plan

## 1. Status and Purpose

This document records the approved architecture for the VanGo MVP. Cycles 0, 1, and 2 are fully implemented locally in Supabase; vans, routes, operations, map tracking, and push notifications remain planned for subsequent cycles.

The mobile client will be developed in Flutter. This repository contains the complete Supabase backend. There will be no custom Node.js API server, custom JWT tokens, custom `bcrypt` implementations, or custom Socket.io servers in the MVP.

## 2. Product Scope

VanGo coordinates school and university transport logistics across four distinct user roles:

- Fleet owner (`owner`);
- Driver (`driver`);
- Guardian (`guardian`);
- Adult student (`student`).

A single user account can accumulate multiple roles. Roles are always contextual to a user's association with a fleet. The fleet represents the tenant, isolating data, permissions, and operations.

Minor students do not have user accounts. One or more guardians manage each minor student. Adult students (18+) maintain their own user accounts and operate under the `student` role.

MVP Included Scope:

- Public fleet marketplace;
- Linkage requests and fleet invitations;
- Management of vans, drivers, students, and guardians;
- Recurrent pickup and drop-off route configurations;
- Daily trip generation and directional confirmation cutoffs;
- Realtime van location tracking during active trips;
- Route optimization, ETA calculations, and automated notifications;
- Incident logging (delays, detours, traffic jams, mechanical issues);
- Immutable auditing and strict multi-tenant isolation.

MVP Excluded Scope:

- Payments, tuition billing, contracts, and driver commissions;
- Pre-approval of fleets by a platform admin;
- Public directories of guardians or students;
- Public rating/review systems for fleets;
- QR codes or automated NFC/Bluetooth boarding detection;
- Custom service area polygon drawing;
- Phone number / SMS authentication.

## 3. Architecture

### 3.1 Hybrid Supabase Approach

The backend utilizes native Supabase services where they reduce complexity without scattering business logic:

- **Supabase Auth:** Email/password registration, email verification, session management, and password recovery;
- **PostgreSQL:** Relational data model, constraints, transactions, historical records, and audit logs;
- **Row Level Security (RLS):** Row-level authorization and tenant isolation across fleets;
- **Database Functions/RPC:** Transactional commands and critical business logic rules;
- **Realtime Broadcast:** Live van position streaming via private per-trip channels;
- **Edge Functions:** External integrations, geocoding, route optimization, and push notifications;
- **Storage:** Avatars, fleet logos, and future attachments;
- **Cron Jobs:** Trip generation, confirmation cutoffs, and raw GPS retention cleanup.

Flutter applications directly execute simple RLS-protected queries and updates. Operations affecting multiple entities or requiring concurrent validation execute via RPC functions. Edge Functions do not duplicate standard CRUD logic; they protect API secrets and coordinate third-party integrations.

### 3.2 Rejected Alternatives

- **Node.js + Supabase:** Requires managing a separate application server, duplicating authentication, authorization, and realtime logic without tangible MVP benefit.
- **Pure Edge Functions for All Operations:** Increases boilerplate code and network latency, reducing initial development speed.
- **Direct Flutter Writes to All Database Tables:** Scatters transactional business logic across mobile clients and increases data corruption risks.
- **Custom Socket.io Server:** Native Supabase private Realtime channels cover all live location requirements.

### 3.3 Backend Folder Structure

```text
supabase/
├── config.toml
├── migrations/
├── seed.sql
├── tests/
│   └── database/
└── functions/
    └── _shared/
```

Migrations are the sole valid mechanism for applying database schema changes.

## 4. Identity, Tenants, and Roles

### 4.1 Identity

`auth.users` manages email, password hashes, email verification state, and session tokens. `profiles` contains domain profile data:

| Field | Rule |
| --- | --- |
| `id` | UUID, FK to `auth.users.id` |
| `full_name` | User's full name |
| `phone` | Optional contact phone |
| `avatar_path` | Optional Storage file path |
| `created_at` | Record creation timestamp |
| `updated_at` | Record update timestamp |

A database trigger initializes a minimal profile upon sign-up. Users can complete profile details prior to email verification. Creating a fleet, issuing invitations, or submitting link requests requires a verified email address.

`profiles` does not duplicate email, password, or role fields. Editable JWT metadata is never used for authorization decisions.

### 4.2 Fleet as Tenant

`fleets` represents the multi-tenant boundary:

| Field | Rule |
| --- | --- |
| `id` | UUID |
| `name` | Commercial fleet name |
| `slug` | Unique public identifier string |
| `description` | Optional public description |
| `logo_path` | Optional logo image path |
| `status` | `draft`, `published`, `suspended`, or `archived` |
| `created_by` | Creating user UUID |
| `created_at` | Creation timestamp |
| `updated_at` | Last update timestamp |

Owners can publish their fleet immediately. `suspended` is reserved for future admin moderation; the MVP does not require platform admin approval before publishing.

Every operational entity includes `fleet_id`. Client applications supply the tenant in every operational payload. The backend does not maintain a global implicit "current tenant".

### 4.3 Memberships and Multiple Roles

`fleet_memberships` establishes a unique relationship between a user and a fleet:

| Field | Rule |
| --- | --- |
| `id` | UUID |
| `fleet_id` | Tenant ID |
| `user_id` | Authenticated user ID |
| `status` | `active`, `suspended`, or `left` |
| `joined_at` | Join timestamp |
| `suspended_at` | Optional suspension timestamp |
| `left_at` | Optional leave timestamp |

`fleet_membership_roles` permits multiple roles within a single membership:

| Field | Rule |
| --- | --- |
| `membership_id` | Membership FK |
| `role` | `owner`, `driver`, `guardian`, or `student` |

A composite primary key prevents duplicate roles. A user can accumulate multiple roles within the same fleet and hold memberships across multiple fleets. Selecting a role in Flutter changes the visual UI experience, not database permissions.

Creating a fleet atomically creates an active membership and assigns the initial `owner` role. No system operation can remove, suspend, or demote the last active owner of a fleet.

### 4.4 Audit Logging

`audit_events` logs sensitive operations:

| Field | Rule |
| --- | --- |
| `id` | Sortable UUID or UUID v4 |
| `fleet_id` | Tenant ID |
| `actor_user_id` | Actor user ID (NULL for background jobs) |
| `action` | Stable action string code |
| `entity_type` | Targeted entity type name |
| `entity_id` | Affected entity UUID |
| `metadata` | Sanitized JSON context |
| `created_at` | Event timestamp |

Standard users cannot modify or delete audit entries. `metadata` stores operational context and modified field names without copying addresses, tokens, or unnecessary personal data.

## 5. Capabilities by Role

### 5.1 Fleet Owner (`owner`)

Owners access only fleets where they hold the `owner` role. Capabilities:

- Edit and publish fleet profiles;
- Register, soft-delete, and view fleet vehicles (vans);
- Assign drivers to the fleet;
- Configure routes, school stop order, schedules, vehicle capacities, and cutoff deadlines;
- Accept or reject student link requests;
- Assign students to vans and routes (overriding submitted preferences if necessary);
- Manage enrollment waitlists;
- Monitor all active live trips across the fleet;
- Perform driver or van substitutions on active/scheduled trips;
- Review operational history and incident logs;
- Broadcast push notifications across fleets, routes, trips, vans, or specific users.

### 5.2 Driver (`driver`)

Drivers access only assigned vans, routes, and trips. Capabilities:

- View scheduled, confirmed, and unconfirmed passenger manifests;
- View route stops, next destination, and ETA;
- Start, complete, or cancel authorized trips;
- Select the next authorized stop point;
- Update passenger statuses (waiting, boarded, dropped-off, absent);
- Stream GPS coordinates during active trips;
- Log incidents (traffic, delays, accidents, mechanical breakdowns, detours);
- Record mandatory justifications for temporary route detours;
- Send categorized messages with optional notes to trip participants.

Drivers cannot edit addresses, schools, student data, vehicle capacities, or permanent route templates.

### 5.3 Guardian (`guardian`)

Guardians can manage multiple minor students. Multiple guardians can link to the same minor student:

- All linked guardians can follow live tracking and confirm daily trips;
- The primary guardian edits student data, residential address, and weekly schedules;
- Only the primary guardian can invite or remove secondary guardians;
- Sensitive changes are recorded in audit logs.

Guardians search fleets, submit link requests, set route preferences, accept fleet invitations, confirm pickup and drop-off trips independently, and follow live tracking exclusively for their linked dependent.

### 5.4 Adult Student (`student`)

Adult students possess a user `profile`, a `fleet_membership` with the `student` role, and a student domain record linked to their account. They search fleets, request linkages, configure route preferences, manage their weekly schedule, confirm daily trips, and follow live tracking exclusively for their own trips.

## 6. Domain Model

This section combines the Cycle 2 schema with planned domain entities for subsequent cycles.

### 6.1 Locations and Public Catalog

`fleet_service_cities` links a fleet to commercial cities served in marketplace searches. Cities represent commercial search filters, not operational geographic boundaries.

`schools` forms a global catalog, empty in Cycle 2 and prepared for future manual data seeding:

- Internal `id`;
- `provider` and `external_id` for idempotency;
- Institution name and type (e.g., elementary, high school, university);
- Structured street address;
- City, latitude, and longitude;
- Data origin metadata and last sync timestamp.

Standard authenticated users cannot write directly to the catalog. Initial school loading for target regions will be executed directly in Supabase. No external importer script or provider API is fixed in Cycle 2.

The marketplace exposes a sanitized view of published fleets filtered by city and covered schools. Operational metrics, distance calculations, and real-time locations are omitted from public endpoints.

### 6.2 Students and Guardians

`students` represents both minor dependents and adult students:

- Identity details and date of birth;
- Current residential street address and coordinates;
- Optional unique `profile_id` (populated exclusively for adult students);
- Creation and update timestamps.

Minor students maintain a `NULL` `profile_id`. The primary guardian controls student data. Full home addresses are disclosed to a fleet owner only when a link request is submitted.

`student_guardians` connects minor students to guardians:

- `student_id`;
- `guardian_user_id`;
- `is_primary` boolean flag;
- Tracking and confirmation permissions;
- Relationship status and timestamps.

Every minor student has exactly one active primary guardian and can have multiple secondary guardians.

### 6.3 Link Requests, Invitations, and Enrollments

`fleet_join_requests` logs enrollment requests submitted by guardians or adult students:

- Fleet ID, requester ID, and student ID;
- Target school ID, shift, directions, and desired days;
- Private residential address snapshot used during evaluation;
- Status (`pending`, `approved`, `rejected`, `waitlisted`, `cancelled`);
- Decision metadata, author, and timestamps.

`join_request_van_preferences` stores up to three preferred vans in rank order. Preferences are informational; the owner can assign any compatible van.

`fleet_invitations` enables fleet owners to invite known email contacts directly.

`fleet_enrollments` represents an approved operational link between a fleet and a student. A student can maintain active enrollments across multiple non-conflicting fleets.

If no seat capacity exists, requests enter a waitlisted status. Capacity evaluates contracted vehicle seat limits, not temporary daily absences.

### 6.4 Vans and Vehicle Assignments

`vans` belongs to a fleet and includes:

- License plate;
- Vehicle model, public identification name, and seating capacity;
- Operational status;
- Summarized public details for marketplace previews;
- Creation and update timestamps.

The MVP targets up to 30 students per van. Seating capacity remains configurable.

A route maintains default van and driver assignments. Daily trips clone these defaults to preserve history. Owners can perform single-trip driver or vehicle substitutions with mandatory justifications and audit logs.

### 6.5 Recurrent Routes

`routes` represents a single direction:

- `fleet_id`;
- Name and status;
- Direction (`going` for morning pickup, `return` for afternoon drop-off);
- Optional `paired_route_id`;
- Scheduled departure and arrival target times;
- Default van and driver assignments;
- Confirmation cutoff and proximity alert parameters;
- Base route optimization version tag.

A pickup route starts at the van departure point, proceeds through confirmed home stops, and terminates at schools. A drop-off route starts at schools, proceeds through confirmed home stops, and terminates at the van depot. Paired routes link opposite directions while maintaining independent schedules and passenger manifests.

`route_schools` acts as a junction table replacing raw ID arrays:

- Route ID and school ID;
- Stop order sequence set by fleet owner;
- Target arrival/departure time window;
- Link status.

`route_schedules` defines operating weekdays, departure times, time zones, operational windows, and confirmation cutoff deadlines (defaulting to 30 minutes before departure).

`route_student_schedules` configures which weekdays a student utilizes a route. Morning pickup and afternoon drop-off operate independently.

### 6.6 Service Days and Daily Trips

`service_days` groups morning and afternoon trips operating on the same calendar date.

`trips` represents a single directional execution:

- `service_day_id`, `fleet_id`, and `route_id`;
- Copied or substituted van and driver assignments;
- Scheduled and actual timestamps;
- Trip status (`scheduled`, `confirmation_closed`, `active`, `completed`, `cancelled`);
- Optimized route geometry utilized for execution;
- Operational summary data.

A daily automated job creates next-day trip records without calling external routing providers.

`trip_passengers` clones scheduled students. Confirmation and operational statuses remain separate:

- Confirmation status: `pending`, `confirmed`, `declined`, `expired`;
- Operational status: `waiting`, `boarded`, `dropped_off`, `absent`.

At cutoff deadlines, `pending` statuses transition to `expired` and are excluded from route optimization.

`trip_stops` stores stop snapshots for the trip execution:

- Origin, home address, school, or final destination;
- Planned and actual sequence numbers;
- Necessary coordinates and street addresses;
- Estimated and actual arrival times;
- Associated student or school references.

Snapshots prevent subsequent address edits from corrupting historical trip logs.

### 6.7 Incidents and Operational Changes

`trip_incidents` records operational events:

- Incident category (traffic, delay, accident, mechanical failure, detour, other);
- Optional text description;
- Author, timestamp, and location coordinates;
- Estimated delay impact and resolution state.

Driver or vehicle substitutions and temporary detours log previous config, new config, actor UUID, timestamp, and justification notes.

### 6.8 Realtime Location Tracking

`trip_location_points` stores GPS telemetry samples:

- `fleet_id` and `trip_id`;
- Latitude, longitude, speed, heading, and accuracy;
- Device capture timestamp and server receive timestamp.

Live location streaming uses a private Supabase Realtime channel `trip:{trip_id}`. Only assigned drivers can publish location points. Fleet owners monitor all active trips. Guardians and adult students listen strictly to trips where their student is `confirmed`.

Tracking activates when a trip transitions to `active` and terminates upon `completed` or `cancelled`.

Role-based location visibility:

- Owner and driver receive full operational route geometries;
- Guardians and adult students receive live van coordinates, school stops, ETA, their specific stop location, and approximate generalized route geometries.

Raw GPS telemetry points are purged after 30 days. Operational summaries, total distance, duration, timetables, incident logs, and audit entries are retained permanently.

### 6.9 Route Optimization and ETA

An Edge Function encapsulates geocoding and routing providers.

Calculation strategy:

1. Recalculate base routes when students, home addresses, schools, or vehicle assignments change;
2. Generate daily trip records via cron without invoking external routing APIs;
3. Accept passenger confirmations until cutoff deadlines;
4. Recalculate route geometry upon cutoff closure only if the confirmed passenger manifest changed;
5. Freeze operational route version for execution;
6. Recalculate exceptionally following authorized detours or incidents.

The MVP supports up to 30 students per vehicle plus school stops. Provider selection evaluates stop limits, regional accuracy, ETA reliability, pricing, and storage compliance terms.

### 6.10 Push Notifications

`device_tokens` stores FCM/APNs tokens per user, device, and platform.

`notifications` logs notification content, category, tenant ID, target audience, and source entity. `notification_deliveries` tracks delivery attempts, outcomes, and deduplication keys.

Automated notification triggers:

- Confirmation window open / upcoming deadline reminder;
- Trip initiated by driver;
- Van approaching (~10 minutes from student stop point);
- Van arrived at student stop point;
- Student boarded vehicle;
- Student dropped off;
- Van arrived at school;
- Operational delay, detour, cancellation, or incident reported.

Proximity alerts evaluate live ETA calculations rather than static radial distances. A deduplication key prevents repetitive spam alerts.

Fleet owners can broadcast custom push messages across fleets, routes, trips, vans, or individual users. Drivers select pre-defined incident categories with optional text notes restricted to active trips.

## 7. Core Workflows

### 7.1 Sign-up and Fleet Setup

1. User creates an account with email and password.
2. Database trigger creates a matching `profiles` record.
3. User completes profile details.
4. User verifies their email address.
5. RPC function creates fleet, membership, and initial `owner` role atomically within a single transaction.
6. Owner keeps fleet in `draft` mode or publishes it to the marketplace.

### 7.2 Marketplace Discovery and Requests

1. Guardian or adult student filters published fleets by city and covered school.
2. User provides full private residential address details.
3. System saves an address snapshot into the link request.
4. Fleet owner approves or rejects the request.
5. Upon approval, system establishes the active enrollment, assigns derived membership roles, and creates audit entries.

### 7.3 Trip Generation and Confirmation

1. Daily cron job creates `service_days`, `trips`, and `trip_passengers` for the next day.
2. Passengers start in `pending` confirmation status.
3. Guardians or adult students confirm or decline morning and afternoon trips independently.
4. System dispatches reminder notifications prior to cutoff deadlines.
5. Unresponsive pending passengers transition to `expired` at cutoff time.
6. Confirmed passengers enter the final optimized route manifest.
7. System recalculates route geometry only if passenger manifest changed.

### 7.4 Trip Execution

1. Assigned driver initiates trip execution.
2. Backend validates driver ID, vehicle ID, status, and tenant.
3. Realtime channel begins accepting location streams.
4. Driver follows authorized stops and updates passenger states (`boarded`, `dropped_off`, `absent`).
5. Backend recalculates ETA, sends push alerts, and persists GPS samples.
6. Driver logs incidents or detours if necessary.
7. Upon completion or cancellation, backend terminates Realtime channel and generates permanent trip summaries.

## 8. Authorization and RLS Policies

### 8.1 Principles

- RLS is enabled on every exposed database table.
- `auth.uid()` identifies calling users.
- Private helper functions verify active memberships and roles per `fleet_id`.
- Functions marked `SECURITY DEFINER` enforce explicit `search_path`, minimal privileges, and internal authorization checks.
- Client applications use only the public Supabase anon key.
- Client applications never specify their own roles, tenant boundaries, or permissions.
- Database indexes cover all columns referenced in RLS policies.

### 8.2 Access Control Matrix Summary

| Resource | Public | Member | Assigned Driver | Owner |
| --- | --- | --- | --- | --- |
| Public Fleet Profile | Sanitized read | Read | Read | Full management |
| Complete User Profile | None | Own profile | Own profile | Sanitized projections |
| Fleet Memberships | None | Own membership | Relevant team | Full tenant management |
| Students & Addresses | None | Own enrollments | Assigned trip manifest | Authorized tenant data |
| Complete Route | None | Limited projection | Assigned route | Complete tenant routes |
| Live Trip Stream | None | Own trip participation | Assigned trip | Complete tenant trips |
| Other Students' Addresses | None | None | Operational stop point | Operational management |
| Audit Logs | None | Own actions | Own actions | Complete tenant audit |

## 9. Data Consistency and Concurrency Controls

Transactional RPC functions enforce critical invariants:

- Unique user memberships per fleet;
- Single active primary guardian per minor student;
- Maximum three van preferences per link request;
- Seating allocations restricted to vehicle capacity;
- Conflict detection for overlapping student, driver, or van schedules;
- Prevention of duplicate active trips for the same vehicle/driver;
- Rejection of GPS streams from unassigned drivers;
- Validation of state machine transitions;
- Protection of historical trip stop snapshots;
- Prevention of last active fleet owner removal/demotion.

## 10. Data Retention and Privacy

- Raw GPS Telemetry: Purged after 30 days.
- Trip Summaries & Logs: Retained permanently.
- Incident & Detour Logs: Retained permanently.
- Passenger Boarding Logs: Retained permanently.
- Audit Logs: Retained permanently (immutable for standard users).
- Device Tokens: Retained until revoked or invalidated.

Retention cleanup cron jobs delete expired records without storing sensitive data in execution logs.

## 11. Delivery Plan (6 Cycles)

1. **Multi-tenant Foundation:** Local Supabase environment, Auth, `profiles`, `fleets`, memberships, roles, RLS policies, and auditing (Completed locally in Cycle 1).
2. **Marketplace and Linkings:** Empty school catalog, commercial cities, `students`, `student_guardians`, invitations, join requests, active links, RLS policies, and auditing (Completed locally in Cycle 2).
3. **Fleet and Planning:** Vehicles (vans), seating capacity, driver assignments, routes, paired directions, school sequence, and weekly schedules.
4. **Daily Operations:** `service_days`, `trips`, passenger manifests, directional confirmations, substitutions, and operational states.
5. **Tracking and Incidents:** Private Realtime streaming, GPS telemetry, privacy-safe location views, incidents, and data retention cleanup.
6. **Route Optimization and Notifications:** Geocoding, route optimization, ETA calculations, push notifications, deduplication, and external API integrations.

## 12. Locally Implemented Cycles Summary

Cycle 1 delivered local Supabase setup, ordered migrations, automatic profile creation, transactional fleet creation, multi-role memberships, private RLS helpers, audit logging, local seed data, and documentation.

Cycle 2 added `schools`, commercial city coverage, `students`, `student_guardians`, invitations, join requests, enrollments, RPC functions, and sanitized audit logging. The school catalog remains empty without mock schools or importer scripts.

## 13. Strict TDD Requirement

Every implementation phase strictly adheres to Test-Driven Development:

1. Write a failing test for a single behavior;
2. Execute test and verify `RED` failure for expected reason;
3. Implement minimal migration, RPC, policy, or code to resolve requirement;
4. Execute test and verify `GREEN` success;
5. Refactor while maintaining green test status;
6. Proceed to next behavior.

## 14. Pending Service Decisions

The following third-party integrations will be evaluated prior to their respective cycles:

- Official school/university catalog API data sources;
- Geocoding, distance matrix, route optimization, and ETA provider API;
- Server-side push notification provider (FCM / APNs / OneSignal);
- GPS sampling rate and persistence interval strategy;
- Data retention legal compliance policies.
