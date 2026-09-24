# Sprint PRD #9 — Fleet-managed student model Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. The authorized execution method is native implementation in this task.

**Goal:** Add a tenant-safe database model for owner-registered students and pre-auth contacts without changing existing guardian, adult, marketplace, or invitation behavior.

**Architecture:** Use one forward-only Supabase migration. Keep student and enrollment provenance in database constraints and immutable-field triggers; store pre-auth contacts against `(fleet_id, enrollment_id)` with owner-only RLS. Preserve existing RPC contracts and route ordinary Flutter reads through `list_fleet_students` in Task #10.

**Tech Stack:** PostgreSQL, Supabase CLI, pgTAP, existing private authorization helpers, Markdown documentation.

**Spec:** [2026-09-23-prd-9-fleet-managed-student-model-design.md](../specs/2026-09-23-prd-9-fleet-managed-student-model-design.md)

## Global Constraints

- Follow `CONTRIBUTING.md`: strict RED → GREEN → Refactor; no implementation before a failing pgTAP test.
- Do not edit applied migrations; create the migration with `supabase migration new prd_9_fleet_managed_student_model`. The installed CLI generated `supabase/migrations/20260924002539_prd_9_fleet_managed_student_model.sql`.
- Keep all SQL, tests, comments, and technical documentation in US English.
- `students.registration_origin` is required, has no generic default, and is immutable after backfill.
- `fleet_enrollments.source_type` and `source_request_id` are immutable after creation and must match exactly.
- `owner_registration` requires `school_id` and `shift`; all contact rows retain `fleet_id` and an enrollment from that fleet.
- Contacts require a nonblank name and at least one nonblank email or phone; only active owners can read them, and clients cannot write them directly.
- Invitation acceptance creates a request, not an enrollment; an invitation-originated request becomes a `join_request` enrollment only after approval.
- Do not add PII to audit metadata, logs, or public projections. Reuse existing private helpers and keep `search_path` empty in privileged functions.
- Preserve the user's existing `vango_app/pubspec.lock` change. Do not commit or push Git changes without separate authorization.
- The user authorized applying this task's migration remotely after local validation. Immediately before deployment, run `supabase --version`, `supabase db push --help`, and `supabase db diff --help`; use `--skip-vault` only if the installed CLI supports it and it is appropriate. Verify the linked project, remote migration history, and dry-run first; apply no unrelated migrations.
- Run local advisors before deployment. After the remote migration is applied, freeze its SQL file; any correction must be a new migration.
- With the installed CLI 2.116.0, run tests that use `\ir` through `python3 supabase/tests/run_database_tests.py`, which expands includes before invoking pgTAP.
- Keep the default seed enabled for the full suite because test `043` checks seeded users. Scope the baseline assertions in tests `008`, `010`, and `016` to their own fixtures so the seeded school and audit events do not contaminate counts.

## Review Focus

1. Existing student creation and direct SQL fixtures need valid origins — test the two RPC outputs and update fixtures in Tasks 1 and 4.
2. Provenance must not be rewritten while unrelated profile or enrollment updates still work — test immutable and allowed updates in Tasks 1 and 2.
3. A null request ID must never turn a direct registration into an ambiguous request, and missing operational fields must fail — test pairing, approval origin, schedule-change compatibility, and school/shift checks in Task 2.
4. Pre-auth contacts must not cross tenant or role boundaries, and unusable/duplicate-primary contacts must fail — test contact constraints and RLS in Task 3.
5. Adding one audit action must not remove any existing actions — test the complete current allowlist from `20260907235815_cycle_4_calendar.sql` in Task 4.

---

### Task 1: Student registration provenance

**Files:**
- Create: `supabase/tests/database/045_fleet_managed_student_model.test.sql`
- Create: `supabase/migrations/20260924002539_prd_9_fleet_managed_student_model.sql`
- Modify: `supabase/tests/database/009_cycle_2_authorization.test.sql`
- Modify: `supabase/tests/database/034_notification_events.test.sql`

**Interfaces:**
- Consumes: Existing `public.create_minor_student(...)`, `public.create_adult_student(...)`, `pg_temp.seed_cycle_2_users()`, and current `public.students` columns.
- Produces: Required `students.registration_origin` with the four valid combinations in the spec; existing RPCs set `guardian_created` and `self_created` respectively.

- [x] **Step 1: Write the first failing schema assertion**

Create the pgTAP file with the standard transaction, extension, and helper setup from `011_students.test.sql`. Start with `select plan(1);` and:

```sql
select has_column(
  'public', 'students', 'registration_origin',
  'students records their registration origin'
);
```

- [x] **Step 2: Run the focused test and confirm RED**

Run: `supabase test db --local supabase/tests/database/045_fleet_managed_student_model.test.sql`

Expected: one pgTAP failure because `registration_origin` is absent.

- [x] **Step 3: Add only the nullable student column**

In the new migration, add `students.registration_origin text` without a default. Leave it nullable and do not add a constraint yet, so the first RED/GREEN slice remains limited to the missing column.

- [x] **Step 4: Reset and confirm the column assertion is GREEN**

Run `supabase db reset`, then rerun the focused `045` test. Expected: the single `has_column` assertion passes.

- [x] **Step 5: Add failing origin-combination and RPC assertions**

Extend `045` with authenticated calls to both RPCs and assertions that a minor is `guardian_created` with a null profile and an adult is `self_created` with `profile_id = auth.uid()`. Also test valid owner-created minor/adult rows and reject invalid type/origin pairs. Keep `plan(N)` synchronized with the assertions. Run `python3 supabase/tests/run_database_tests.py` before implementing the check or replacing either RPC; the origin assertions and invalid-state assertions must fail.

For the minor assertion, use:

```sql
select is(
  (select registration_origin from public.students where full_name = 'PRD9 Minor'),
  'guardian_created',
  'guardian-created minor records its origin'
);
```

- [x] **Step 6: Backfill, constrain, and update the existing RPCs**

Map existing minors to `guardian_created` and profiled adults to `self_created`; make the column `NOT NULL`; replace `students_profile_type_valid` with a check allowing only the four combinations in the spec; and leave `students_adult_profile_id_key` unchanged. Copy the current signatures and bodies of `create_minor_student` and `create_adult_student` from `20260906210854_create_student_functions.sql`, adding only explicit origin values to their inserts. Preserve validation, error mapping, grants, the minor's primary guardian row, and the adult's self-profile link. Reset and rerun `045`, `011_students`, and `009_cycle_2_authorization`; expected: the new origin and combination assertions and existing student tests pass.

- [x] **Step 7: Add and test the student-origin immutability trigger**

Add pgTAP cases that reject changing `registration_origin` with SQLSTATE `23514`, permit an owner-created adult's `profile_id` to be linked, and permit unrelated student updates. Run the focused test before adding the trigger and confirm the mutation assertion fails; then add a `BEFORE UPDATE OF registration_origin` trigger that rejects only a changed value. Reset and rerun `045`.

- [x] **Step 8: Update direct SQL fixtures with explicit origins**

In `034_notification_events.test.sql`, set both directly inserted minors to `guardian_created`. In `009_cycle_2_authorization.test.sql`, add `registration_origin = 'guardian_created'` to the denied direct-write statement so its intended `42501` assertion remains the failure reason. Do not add a default to the production column.

- [x] **Step 9: Reset the local database and run student regressions**

Run: `supabase db reset`

Then run: `python3 supabase/tests/run_database_tests.py`

Expected: all focused student provenance, old RPC, and direct-write assertions pass.

### Task 2: Enrollment provenance and operational invariants

**Files:**
- Modify: `supabase/migrations/20260924002539_prd_9_fleet_managed_student_model.sql`
- Modify: `supabase/tests/database/045_fleet_managed_student_model.test.sql`
- Modify: `supabase/tests/database/014_enrollments.test.sql`
- Modify: `supabase/tests/database/022_schedule_changes.test.sql`

**Interfaces:**
- Consumes: Student provenance from Task 1; current `fleet_enrollments` source request, school, and shift fields.
- Produces: Required `source_type` values `join_request` and `owner_registration`; exact pairing with `source_request_id`; direct owner enrollments require school and shift.

- [x] **Step 1: Write a failing assertion for approved-request provenance**

In `014_enrollments.test.sql`, assert that the enrollment produced by `approve_transport_request` has `source_type = 'join_request'`. Add a corresponding `045` assertion that the column exists and run the focused files before changing the migration.

Run: `python3 supabase/tests/run_database_tests.py`

Expected: the new source assertion fails because `source_type` does not exist.

- [x] **Step 2: Add the source column and make the request ID nullable**

In the migration, add `source_type text NOT NULL DEFAULT 'join_request'` and drop `NOT NULL` from `source_request_id`, but do not add the new checks yet. Reset and rerun `045` and `014`; the new column and approved-request source assertions must now pass.

- [x] **Step 3: Test request pairing and owner operational fields before adding checks**

Extend `045` with one valid direct-owner enrollment and `throws_ok` cases for both inverse pairings. Include a direct-owner row missing `school_id` and `shift`; confirm the invalid-pair and missing-field assertions fail before the new constraints exist.

- [x] **Step 4: Add source and owner-field database checks**

Add allowed-source and exact-pairing checks plus `CHECK (source_type <> 'owner_registration' OR (school_id IS NOT NULL AND shift IS NOT NULL))`. Preserve the existing unique source-request constraint, `shift_valid` check, and fleet/enrollment composite key. Reset and run the focused source tests; expected: valid request and owner rows pass, both inverse pairings and missing owner fields fail with `23514`.

- [x] **Step 5: Add and test immutable enrollment provenance**

Add assertions that changes to either `source_type` or `source_request_id` fail with SQLSTATE `23514`, while a change to `shift` remains permitted. Confirm RED before adding a `BEFORE UPDATE OF source_type, source_request_id` trigger; install the trigger after source backfill and check creation.

- [x] **Step 6: Verify invitation semantics and schedule-change compatibility**

Keep `015_fleet_invitations.test.sql`'s existing assertions that acceptance creates a pending request and no enrollment. In that fixture, approve the invitation-originated request using `../_approval.psql` and assert the resulting enrollment uses `source_type = 'join_request'`. In `022_schedule_changes.test.sql`, add an owner-registration enrollment with a valid school/shift and assert `request_schedule_change` succeeds using those enrollment fields with no source request.

- [x] **Step 7: Reset and run enrollment regressions**

Run: `supabase db reset`

Then run: `python3 supabase/tests/run_database_tests.py`

Expected: marketplace and approved invitation requests remain `join_request`; invitation acceptance alone creates no enrollment; direct enrollments satisfy school/shift and schedule-change requirements.

### Task 3: Private enrollment contacts

**Files:**
- Modify: `supabase/migrations/20260924002539_prd_9_fleet_managed_student_model.sql`
- Modify: `supabase/tests/database/045_fleet_managed_student_model.test.sql`

**Interfaces:**
- Consumes: `(fleet_id, id)` enrollment uniqueness, `private.has_fleet_role(uuid, uuid, text)`, and `private.set_updated_at()`.
- Produces: `public.fleet_student_contacts` with tenant-safe enrollment FK, one-primary-per-enrollment index, owner-only `SELECT`, and no direct client writes.

- [x] **Step 1: Write failing table, shape, and foreign-key tests**

Add `has_table('public', 'fleet_student_contacts', ...)`, then tests for one valid primary contact; rejection of blank name, no contact method, mismatched fleet/enrollment, and a second primary; and acceptance of a secondary contact. Run `045` and confirm the missing-table assertion fails.

- [x] **Step 2: Add the contact table and constraints**

Create columns `id`, `fleet_id`, `enrollment_id`, `contact_type`, `full_name`, `email`, `phone`, `is_primary`, `created_at`, and `updated_at`. Use `extensions.gen_random_uuid()` for `id` and the defaults from the spec for timestamps. Add allowed contact types, nonblank name/email/phone and at-least-one-method checks, a restrictive composite FK to `(fleet_id, id)`, an enrollment lookup index, and a partial unique primary index.

- [x] **Step 3: Add and test `updated_at` behavior**

Add a `BEFORE UPDATE` trigger using `private.set_updated_at()`. Set a test contact's `updated_at` to a past timestamp, update its phone, and assert the stored timestamp advances. Confirm the assertion fails before the trigger exists.

- [x] **Step 4: Write failing access tests, then add RLS and grants**

Using `pg_temp.seed_foundation()`, create contact rows in two fleets. Test that an owner sees only their fleet, a same-fleet driver, guardian, and student see no contact rows, and a different-fleet owner sees none. Test that `anon` cannot select and authenticated users cannot insert, update, or delete directly. Add `ENABLE ROW LEVEL SECURITY`, revoke all table privileges, grant only `SELECT` to `authenticated`, and add a `FOR SELECT` policy backed by `private.has_fleet_role(fleet_id, auth.uid(), 'owner')`.

- [x] **Step 5: Reset and run contact tests**

Run: `supabase db reset`

Then run: `python3 supabase/tests/run_database_tests.py`

Expected: all shape, FK, cardinality, timestamp, tenant, owner/driver/guardian/student role, and direct-write assertions pass.

### Task 4: Audit compatibility, documentation, and deployment

**Files:**
- Modify: `supabase/migrations/20260924002539_prd_9_fleet_managed_student_model.sql`
- Modify: `supabase/tests/database/045_fleet_managed_student_model.test.sql`
- Modify: `README.md`
- Modify: `be-tech-plan.md`
- Modify: `supabase/tests/database/008_cycle_2_schema.test.sql`
- Modify: `supabase/tests/database/010_marketplace.test.sql`
- Modify: `supabase/tests/database/016_cycle_2_audit_privacy.test.sql`
- Modify: `deliverables.md` only after validations and the remote migration actually succeed

**Interfaces:**
- Consumes: Current full audit allowlist in `20260907235815_cycle_4_calendar.sql` and the schema behaviors from Tasks 1–3.
- Produces: `fleet_student_registered` allowed without removing any current action; docs accurately describe the deployed model and actual validation state.

- [x] **Step 1: Write a failing audit allowlist test**

In `045`, add two pgTAP `lives_ok` assertions: one inserts audit rows for every action in the current Cycle 4 allowlist; the other inserts `fleet_student_registered`. Use the seeded fleet/actor and `entity_type = 'student'`. Confirm the old list still passes and RED occurs specifically on the new action.

- [x] **Step 2: Extend the latest audit constraint without losing actions**

In the new migration, replace `audit_events_action_valid` by copying the full latest list from `20260907235815_cycle_4_calendar.sql` and adding `fleet_student_registered`. Keep the current entity-type allowlist, which already contains `student`.

- [x] **Step 3: Run the focused audit test and full local validation**

Run `supabase db reset` with the configured seed, then run:

```bash
python3 supabase/tests/run_database_tests.py
supabase db lint --local --schema public,private --fail-on error
supabase db advisors --local --type all --fail-on error
git diff --check
```

Expected: focused and full pgTAP suites pass; lint has zero errors; diff check emits no whitespace errors. Run the repository `software-quality-gate` after capturing `git status`, and check `git status` again afterward. Do not make SonarQube a DoD unless the repo has a real Sonar configuration.

- [x] **Step 4: Update technical documentation**

In `be-tech-plan.md` sections 6.2–6.3, document student origin, direct owner enrollments, source pairing, and private enrollment contacts. Add a current student-registration paragraph to `README.md` that distinguishes guardian/self onboarding from owner-managed registration and states that invitation acceptance still creates a request. Do not rewrite historical Cycle 2 scope or release claims.

- [ ] **Step 5: Verify remote target and pending migration set**

Run `supabase --version`, `supabase db push --help`, and `supabase db diff --help`. Run `supabase migration list --linked` and verify the linked project identity against `supabase/config.toml` and the intended VanGo project. Use `--skip-vault` only if the installed CLI supports it and it is appropriate. Run the supported `supabase db push --linked --dry-run` command. Proceed only if the dry run shows exactly `20260924002539_prd_9_fleet_managed_student_model` and no unrelated pending migration.

- [ ] **Step 6: Apply the authorized migration and verify remote history**

Run the supported `supabase db push --linked` command, adding `--skip-vault` only if supported and appropriate. Do not run pgTAP against the remote project. Verify the new version is applied with `supabase migration list --linked`, then run read-only `supabase db diff --linked --schema public,private` and inspect any output for unrelated drift. Once verified remotely, do not edit this migration; make any later correction in a new migration.

- [ ] **Step 7: Record only completed work and preserve Git state**

After the remote version is verified, add a Sprint PRD #9 entry to `deliverables.md` with actual commands and outputs only. Capture final `git status --short --branch`; confirm `vango_app/pubspec.lock` remains untouched by this task and leave all changes uncommitted.
