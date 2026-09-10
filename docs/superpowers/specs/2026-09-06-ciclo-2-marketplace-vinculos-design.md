# Cycle 2 — Marketplace and Linkings Design Specification

**Date:** September 6, 2026  
**Status:** Approved for planning  
**Baseline:** Cycle 1 completed locally at `9d42709`

## Goal

Deliver the empty educational institution catalog, commercial fleet coverage, student/guardian management, public marketplace discovery, and link request / invitation / enrollment workflows. The cycle preserves multi-tenant isolation and student data privacy.

## Approved Scope

Cycle 2 Includes:

- Global table `schools`, initialized empty;
- Commercial city coverage in `fleet_service_cities`;
- Commercial school coverage in `fleet_service_schools`;
- Minor dependent and adult student domain profiles;
- Primary and secondary guardian relationships;
- Invitations for secondary guardians;
- Public search functions for active schools and published fleets;
- Link requests initiated from marketplace;
- Invitations initiated by fleet owners;
- Active and ended enrollments in `fleet_enrollments`;
- RLS policies, RPC functions, sanitized audit logging, and pgTAP tests.

Cycle 2 Excludes:

- Seeding real schools or universities;
- Automated importer scripts or third-party API integrations (INEP, e-MEC, Google, Mapbox, OSM);
- Catalog administration UI;
- Vehicle preferences;
- Vehicle capacity checks, live availability, or waitlists;
- Vans, drivers, routes, and schedules;
- Email dispatch or push notifications;
- Modifications to Flutter mobile application code.

## Architecture

Flutter applications use the Data API for simple reads and RLS-protected updates. Database Functions handle student creation, invitations, status transitions, membership role propagation, and audit logs.

No Edge Functions are created in this cycle. The backend returns the raw 32-byte invitation token exactly once upon creation; Flutter handles deep linking `/invite/:token` during sign-up/login callbacks. The database stores strictly the SHA-256 hash of tokens.

## Data Model

### `schools`

Curated global catalog. Standard authenticated and anonymous users cannot write to this table directly.

Minimum fields:

- `id uuid`;
- `provider text`: `inep` or `emec`;
- `external_id text`;
- `institution_type text`: `school` or `higher_education`;
- `name text`;
- `postal_code text`;
- `street text`;
- `street_number text`;
- `address_complement text` optional;
- `neighborhood text`;
- `city_name text`;
- `city_ibge_code text` (7 digits);
- `state_code text` (2 uppercase letters);
- `latitude numeric` and `longitude numeric` optional;
- `status text`: `active` or `inactive`;
- `source_updated_at date`;
- `created_at` and `updated_at`.

Unique constraint on `(provider, external_id)`.

### `fleet_service_cities`

Tracks commercial city coverage for a fleet.

Minimum fields:

- `fleet_id`;
- `city_ibge_code`;
- `city_name`;
- `state_code`;
- `created_by`;
- `created_at`.

Composite primary key: `(fleet_id, city_ibge_code)`. Active members view; only owners insert/delete records.

### `fleet_service_schools`

Links fleets to commercially served institutions.

Minimum fields:

- `fleet_id`;
- `school_id`;
- `created_by`;
- `created_at`.

Composite primary key: `(fleet_id, school_id)`.

### `students`

Represents minor dependents and adult students across fleets.

Minimum fields:

- `id`;
- `student_type`: `minor` or `adult`;
- `profile_id` optional and unique;
- `full_name`;
- `birth_date`;
- Structured residential street address;
- `created_by`;
- `created_at` and `updated_at`.

Adult students possess a non-null `profile_id`; minor dependents do not.

### `student_guardians`

Links minor dependents to guardians.

Minimum fields:

- `student_id`;
- `guardian_user_id`;
- `is_primary` boolean flag;
- `status`: `active` or `removed`;
- `joined_at`;
- `removed_at` optional.

Every minor student has exactly one active primary guardian.

### `fleet_join_requests`

Records marketplace requests and invitation response forms.

Minimum fields:

- Fleet ID, requester ID, student ID, school ID;
- Source (`marketplace` or `invitation`);
- Target shift (`morning`, `afternoon`, `evening`, `full_time`);
- Target directions (`going`, `return`);
- Operating weekdays (1-7);
- Structured address snapshot;
- Request status (`pending`, `approved`, `rejected`, `cancelled`).

### `fleet_enrollments`

Represents active or ended links between fleets and students.

Minimum fields:

- `id`;
- `fleet_id`;
- `student_id`;
- Unique `source_request_id`;
- Status (`active` or `ended`);
- `started_at`;
- `ended_at`, `ended_by`, and `end_reason` optional.

---

## Authorization & Privacy Rules

- Anonymous users (`anon`) can execute only public search functions (`search_schools`, `search_marketplace`).
- Fleet owners view student addresses only while requests are `pending` or enrollments remain `active`.
- Upon rejection, cancellation, or enrollment termination, student address details omit PII in owner views.
- Audit logs omit personal identifiers, raw tokens, street addresses, and coordinates.
