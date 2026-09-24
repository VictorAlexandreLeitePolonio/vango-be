# Sprint PRD #10 — Owner fleet student registration contracts

**Date:** September 24, 2026
**Status:** Approved for implementation after review corrections
**Related work:** [Sprint PRD #8](https://github.com/VictorAlexandreLeitePolonio/vango-be/issues/8), [Task #9](https://github.com/VictorAlexandreLeitePolonio/vango-be/issues/9), [Task #10](https://github.com/VictorAlexandreLeitePolonio/vango-be/issues/10), [Task #12](https://github.com/VictorAlexandreLeitePolonio/vango-be/issues/12)
**Schema dependency:** `supabase/migrations/20260924002539_prd_9_fleet_managed_student_model.sql`

## Goal

Provide authenticated fleet owners with a dedicated, transactional contract to register minors and adults already served by their fleet, and a fleet-scoped read contract for active students. The registration must not reuse guardian/self-onboarding, marketplace, or invitation flows.

The write contract creates a new student for each new logical command. It does not attempt to identify existing people by name, birth date, address, or contact details. Retries of the same logical command are idempotent through `p_command_id`.

## Scope

- Add a database RPC to create a fleet-managed student, direct enrollment, primary operational contact, and audit event atomically.
- Add an owner-only RPC listing active fleet students across enrollment origins with the minimum projection required by the owner student-management UI.
- Add enrollment receipt fields, constraints, index, and immutability for registration idempotency.
- Add pgTAP coverage for permissions, domain validation, atomicity, idempotent retries, privacy, and read isolation.
- Preserve existing guardian-created minor and self-created adult functions and marketplace/invitation behavior.
- Deploy the validated migration to the linked Supabase project using the task's approved remote migration workflow.

This task does not resolve the active fleet from user access context (#11), implement Flutter screens/services (#12), perform fallback/logging cleanup (#13), or run integrated app validation (#14). The existing shared Flutter enrollment service used by driver routes is not changed here.

## Write contract

Add a dedicated `public.create_fleet_managed_student(...)` RPC using the existing `SECURITY DEFINER`, empty `search_path`, domain-error, email-confirmation, role-check, and student-validation patterns. Revoke execution from `PUBLIC` and `anon`; grant it to `authenticated`. The function still performs every authorization check itself.

The input contains:

- `p_fleet_id uuid` and `p_command_id uuid`;
- student type, name, birth date, and the existing student address fields;
- required `p_latitude numeric` and `p_longitude numeric` resolved for the student's address;
- `p_school_id uuid` and `p_shift text`;
- the primary operational contact's name, optional email, and optional phone.

The RPC returns the same `student_id` and `enrollment_id` for successful initial calls and valid replays. The client does not supply `registration_origin`, `source_type`, `source_request_id`, `profile_id`, `created_by`, `contact_type`, `is_primary`, or generated row IDs. The server derives them.

### Authorization and validation

Before creating or returning a registration result, require:

1. An authenticated user with a confirmed email.
2. An existing fleet and an active `owner` role for that user in that fleet. Driver-only membership is insufficient. A missing active owner role returns `forbidden` without revealing other fleet data.
3. An active school included in `fleet_service_schools` for the selected fleet. The fleet does not need to be published. City membership in `fleet_service_cities` is not an additional requirement for this direct flow.
4. A valid shift from the existing supported shift values.
5. Valid student and address fields using `private.validate_student_fields` with the same canonical values that will be persisted.
   Both coordinates are required for this operational registration. Reject a missing or partial pair and values outside latitude `[-90, 90]` or longitude `[-180, 180]`; do not infer, geocode, or hardcode fallback coordinates in the database.
6. A student type consistent with age: `minor` is under 18; `adult` is 18 or older.
7. A nonblank primary contact name and at least one nonblank email or phone.

Invalid/missing inputs, unsupported shifts, age/type mismatches, and inactive or uncovered schools return `invalid_input`. The function must return stable domain codes and must not expose raw SQL errors.

### Server-derived records

For a minor, create:

- `students.registration_origin = 'fleet_owner_created'`;
- `students.profile_id = NULL`;
- `students.created_by = auth.uid()`;
- a primary `fleet_student_contacts` row with `contact_type = 'guardian'`.

For an adult, create:

- `students.registration_origin = 'fleet_owner_created'`;
- `students.profile_id = NULL`;
- `students.created_by = auth.uid()`;
- a primary `fleet_student_contacts` row with `contact_type = 'student'`.

For both types, create one active `fleet_enrollments` row with `source_type = 'owner_registration'`, `source_request_id = NULL`, the selected school and shift, and one primary contact. Do not create an Auth account, `student_guardians` row, or `fleet_join_requests` row. Existing `create_minor_student`, `create_adult_student`, marketplace, and invitation flows retain their behavior.

Insert the student, enrollment, contact, and `fleet_student_registered` audit event in the same RPC transaction. Audit metadata may contain non-sensitive operational identifiers such as `school_id`, `shift`, and student type. It must not contain a name, birth date, address, contact values, coordinates, raw payload, or payload hash. A failed write, including an audit failure, leaves none of these records behind.

## Idempotency

Use the enrollment as the registration receipt; do not add a generic idempotency subsystem or a separate receipt table.

Add these columns to `public.fleet_enrollments`:

- `registration_command_id uuid`;
- `registration_payload_hash bytea`.

For `source_type = 'owner_registration'`, both fields are required. For `source_type = 'join_request'`, both fields are null. Add a partial unique index on `(fleet_id, registration_command_id)` where `source_type = 'owner_registration'`. Extend the existing enrollment provenance immutability trigger so the command ID and payload hash cannot be changed after creation.

Update existing SQL test fixtures that insert `owner_registration` enrollments directly to supply explicit unique command IDs and hashes. Do not add a generic database default to keep those fixtures passing.

The hash is SHA-256 over a deterministic JSONB payload built from the normalized values actually persisted, including latitude and longitude. Normalize text once, use `NULL` for blank optional values, and use explicit stable keys and types. Validation and persistence consume those same canonical values. Do not hash raw parameters or store the raw command payload in the receipt.

Use `students.created_by` to verify the actor on replay. The RPC sets it to `auth.uid()`; authenticated clients have no direct update grant on `students`, and supported write RPCs must not change it. Do not add a duplicate `registration_actor_user_id` column.

After authentication, email, and active-owner checks, the RPC looks up the receipt by fleet and command ID:

- Same fleet, command ID, actor (`students.created_by`), and payload hash: return the original student and enrollment IDs without creating a student, enrollment, contact, or audit event.
- Same fleet and command ID with a different actor or payload hash: return `idempotency_conflict`.
- New command ID: create a new registration even when personal data matches another student.

The partial unique index is the final concurrency barrier. The RPC must handle a concurrent unique-key collision by comparing the winning receipt and returning its result or `idempotency_conflict`; a preflight `SELECT` alone is not sufficient. A losing attempt must not leave partial rows or duplicate audit events.

Do not expose either receipt field through an RPC response, read projection, audit metadata, or error message.

Idempotency is not person deduplication. No fuzzy or exact name/date matching is performed. Future account claiming must link to an existing student through its own explicit identity/linking contract.

## Read contract

Add `public.list_fleet_students(p_fleet_id uuid)` as an owner-only, fleet-scoped read RPC. Revoke execution from `PUBLIC` and `anon`; grant it to `authenticated`. It returns active enrollments regardless of `source_type`, so future marketplace and invitation enrollments use the same contract. It excludes ended enrollments.

The result projection is:

| Field | Source/purpose |
| --- | --- |
| `enrollment_id` | Enrollment identity for later operational allocation |
| `student_id` | Student identity |
| `student_type` | Minor/adult UI behavior |
| `full_name` | Owner student list |
| `postal_code` | Structured address |
| `street` | Structured address |
| `street_number` | Structured address |
| `address_complement` | Structured address |
| `neighborhood` | Structured address |
| `city_name` | Structured address |
| `state_code` | Structured address |
| `school_id` | Enrollment school identity |
| `school_name` | Display label |
| `shift` | Enrollment operational schedule |

Return address fields separately; Flutter formats them for display. Order the result deterministically by `lower(full_name), student_id`. Do not return `profile_id`, Auth data, contact names/emails/phones, latitude, or longitude. The RPC verifies active owner membership. A nonexistent fleet and a fleet outside the caller's authorized scope both return `not_found`, preventing the read contract from becoming a fleet-discovery endpoint. Flutter uses this RPC instead of reading `fleet_student_contacts` directly. The existing driver-route service remains outside this contract.

## Error contract

| Code | Meaning |
| --- | --- |
| `unauthenticated` | No authenticated user |
| `email_unverified` | Authenticated user has not confirmed email |
| `forbidden` | Write caller lacks an active owner role for the selected fleet |
| `invalid_input` | Invalid student, age/type, address, contact, shift, or school coverage input |
| `not_found` | Read fleet is missing or outside the caller's authorized scope |
| `idempotency_conflict` | Command ID was reused in the same fleet with another actor or canonical payload |

The new registration RPC does not invent a `student_conflict` case for matching personal data. Existing global error codes and existing onboarding function behavior remain unchanged.

## Tests and acceptance criteria

Write focused pgTAP tests first and verify each targeted test fails for the expected missing behavior before implementing it.

- An owner creates a minor and an adult without a profile; origin, profile, actor, contact type, enrollment source, request ID, school, shift, and primary status are server-derived correctly.
- Owner creation creates no `student_guardians` or `fleet_join_requests` rows and does not create an Auth account.
- A driver-only user, an owner from another fleet, an anonymous user, and an unconfirmed user cannot create students; a confirmed active owner can.
- A nonexistent fleet or unauthorized fleet read returns `not_found`; owner read succeeds.
- The fleet may be unpublished; the selected school must be active and in the fleet's configured school coverage.
- Invalid ages, type/age mismatches, address, missing/partial/out-of-range coordinates, contact, or shift fail with stable domain errors and no partial writes.
- Existing minor/adult self-service, marketplace, and invitation regression tests continue to pass.
- A same-fleet replay with the same command ID, actor, and canonical payload returns the same student/enrollment IDs and leaves exactly one student, enrollment, primary contact, and registration audit event.
- Equivalent canonical values (for example, a trimmed name and blank optional field normalized to null) replay successfully rather than conflict.
- Reusing the same fleet/command ID with another actor or a different canonical payload returns `idempotency_conflict` and creates no extra side effects.
- A new command ID with the same personal data creates a separate student/enrollment/contact/audit event; no person matching is performed.
- The unique partial index prevents duplicate enrollments for concurrent calls with the same fleet and command ID. If the existing database test harness can run independent concurrent sessions, prove that the calls produce one student and one enrollment; do not add a new test framework solely for this check.
- A failure during student, enrollment, contact, or audit creation rolls back the full registration.
- Audit metadata contains no name, birth date, address, contact value, coordinates, raw payload, or payload hash.
- `list_fleet_students` returns active enrollments from both source types and includes `enrollment_id` plus the specified structured fields.
- `list_fleet_students` orders rows by `lower(full_name), student_id` across repeated calls.
- The read projection excludes `profile_id`, email, phone, latitude, and longitude; ended enrollments and students from other fleets are not returned.

## Migration and delivery

Create a new migration with `supabase migration new prd_10_owner_fleet_student_rpcs`; use the generated filename and leave the applied Task #9 migration immutable. The new migration may add the two receipt columns, source-specific constraints, partial unique index, immutability coverage, and the two RPCs.

Follow the database task workflow:

1. RED targeted pgTAP tests.
2. Implement the migration and RPCs.
3. GREEN targeted tests, then `supabase db reset` and the full database pgTAP runner.
4. Run database lint, advisors, review, and `git diff --check`.
5. Inspect linked project identity and migration history; dry-run must contain exactly the Task #10 migration and no unexpected migrations.
6. Push the validated migration remotely, verify the remote migration history, then freeze the migration. Any later correction is a new migration.
7. Update delivery documentation only after the remote migration is confirmed.

Work on `codex/task-10-owner-fleet-student-rpcs`, preserve unrelated workspace changes, and keep the implementation in its task branch. Task #11, #12, #13, and #14 remain separate tasks.

## References

- `CONTRIBUTING.md` — TDD, migration, RLS, privacy, audit, and validation rules.
- `supabase/migrations/20260924002539_prd_9_fleet_managed_student_model.sql` — origins, direct enrollment, contacts, owner role checks, and audit action.
- `supabase/migrations/20260906201646_create_cycle_2_authorization.sql` — student/address validation and role helpers.
- `supabase/migrations/20260906211326_create_join_request_functions.sql` — owner-scoped read RPC and current `not_found` access pattern.
- `supabase/migrations/20260907235817_cycle_4_generation.sql` — command ID, payload hash, and idempotency-conflict pattern.
- `vango_app/lib/features/fleet/services/fleet_service.dart` — current enrollment read used by fleet and driver paths.
- `vango_app/lib/features/fleet/screens/fleet_owner_dashboard_screen.dart` — fields displayed in the current owner student list.
