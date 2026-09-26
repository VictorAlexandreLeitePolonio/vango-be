# Sprint PRD #9 — Fleet-managed student model

**Date:** September 23, 2026
**Status:** Implementation validated locally; remote application pending
**Related work:** [Sprint PRD #8](https://github.com/VictorAlexandreLeitePolonio/vango-be/issues/8), [Task #9](https://github.com/VictorAlexandreLeitePolonio/vango-be/issues/9)
**Base:** Current local migrations and the approved model decisions in this task.

## Goal

Allow an active fleet owner to enroll an existing minor or adult student directly into that fleet. The model must distinguish who originally registered a student from whether the student currently has a profile, and must distinguish owner registration from a marketplace or invitation request.

Direct owner registration must not create a `fleet_join_requests` row, create an Auth account, or add an unauthenticated contact to `student_guardians`. The existing guardian-led minor flow and self-registered adult flow remain supported.

## Scope

- Add an explicit, immutable student registration origin and backfill existing students.
- Add an explicit enrollment source and permit a null request ID only for direct owner registration.
- Store private pre-auth contact details against a specific fleet enrollment.
- Add tenant-scoped RLS, integrity constraints, indexes, and the audit action needed by Task #10.
- Add pgTAP coverage for the new model, RLS, and regressions in the existing student creation RPCs.

This task does not implement the owner-facing RPC or list contract from Task #10, access-context routing from Task #11, Flutter UI from Task #12, cleanup from Task #13, or end-to-end validation from Task #14. Those tasks consume this schema. No prior migration is edited; changes use a new forward migration.

## Student registration origin

Add `students.registration_origin` with these values:

| `student_type` | `registration_origin` | `profile_id` | Meaning |
| --- | --- | --- | --- |
| `minor` | `guardian_created` | `NULL` | A guardian created the dependent record through the existing flow. |
| `minor` | `fleet_owner_created` | `NULL` | A fleet owner registered a minor without creating an account for the contact. |
| `adult` | `self_created` | Required | The adult student created their own record. |
| `adult` | `fleet_owner_created` | Nullable | A fleet owner registered the adult; the profile can be linked later. |

Reject all other combinations. In particular, minors cannot be `self_created`; adults cannot be `guardian_created`; `self_created` adults require a profile; minors cannot have a profile. Keep the existing unique adult-profile index.

The field records provenance, not current account state. If an owner-created adult later links an account, keep `registration_origin = 'fleet_owner_created'` and set `profile_id`; do not rewrite history to `self_created`.

Enforce that provenance in PostgreSQL with a `BEFORE UPDATE OF registration_origin` trigger. It must reject a changed value while allowing unrelated student updates and a later `profile_id` link. Backfill existing rows before installing the trigger.

Backfill existing minors to `guardian_created` and existing profiled adults to `self_created`, then make the field non-null and enforce the combinations above. The current model has no owner-created students to backfill.

Update the existing `create_minor_student` and `create_adult_student` functions in the new migration to write their corresponding origin. Preserve their current guardian-row and profile-link behavior.

## Enrollment source

Add `fleet_enrollments.source_type text NOT NULL DEFAULT 'join_request'` with `join_request` and `owner_registration` values. Keep `source_request_id` as a foreign key, make it nullable, and enforce this exact pairing:

- `join_request` requires a non-null `source_request_id`.
- `owner_registration` requires a null `source_request_id`.

Backfill existing rows as `join_request`. Give the new column a `join_request` default so existing approved-request RPCs that omit the column retain their current behavior; the owner-registration RPC in Task #10 must set `owner_registration` explicitly. Preserve uniqueness for non-null source request IDs and the existing one-active-enrollment-per-fleet/student index.

Direct registrations must carry their operational `school_id` and `shift` on the enrollment. Enforce `source_type <> 'owner_registration' OR (school_id IS NOT NULL AND shift IS NOT NULL)` as a database constraint, in addition to validation in Task #10. The existing schedule-change flow can then use enrollment values when no source request exists; it must not synthesize a request to satisfy a legacy read path.

Enrollment provenance is immutable after creation. A `BEFORE UPDATE OF source_type, source_request_id` trigger must reject changes to either value while allowing updates to enrollment status and operational fields. Install it after source backfill.

## Private pre-auth contacts

Add `public.fleet_student_contacts` for private contact details attached to a specific enrollment. Use these fields:

| Field | Rule |
| --- | --- |
| `id` | UUID primary key defaulting to `extensions.gen_random_uuid()` |
| `fleet_id` | Required; retained for tenant checks and indexed queries |
| `enrollment_id` | Required; enrollment owning the contact |
| `contact_type` | `guardian` or `student` |
| `full_name` | Required and nonblank |
| `email` | Optional text; if present, nonblank |
| `phone` | Optional text; if present, nonblank |
| `is_primary` | Required boolean |
| `created_at`, `updated_at` | Required `timestamptz` values defaulting to `now()`; add a `BEFORE UPDATE` trigger that calls `private.set_updated_at()` |

Require at least one nonblank email or phone; store an omitted value as `NULL`, not an empty string. Do not add strict phone or email-format rules in this model. Allow multiple contacts per enrollment and enforce at most one primary contact with a partial unique index on `(fleet_id, enrollment_id)` where `is_primary` is true. Task #10 creates one primary contact for an owner registration; secondary-contact management is outside this task.

Keep `fleet_id` even though it can be derived from the enrollment. Enforce that the enrollment belongs to that same fleet with a composite foreign key to `(fleet_id, id)` on `fleet_enrollments`. Use restrictive deletion behavior to preserve operational history. Add an index covering `(fleet_id, enrollment_id)` so tenant and enrollment lookups and the foreign-key relationship are supported.

For the MVP RPC, a minor gets a `guardian` contact and an owner-created adult gets a `student` contact. This contact is not a `student_guardians` row and does not grant access to the app.

## Access and privacy

- Enable RLS on `fleet_student_contacts`.
- Grant `SELECT` only to `authenticated`; permit active owners to select contact rows only for their own fleet using the existing `private.has_fleet_role` helper, which checks active membership and role.
- Deny drivers, guardians, students, users from another fleet, and anonymous users.
- Revoke direct client `INSERT`, `UPDATE`, and `DELETE`; writes go through the transactional owner RPC in Task #10.
- Keep the normal Flutter read path on `list_fleet_students`; Flutter must not query the contact table directly. RLS remains defense in depth.
- Do not add contact PII to public projections, audit metadata, application logs, or error messages. The list RPC contract in Task #10 will define any minimal fields needed by the owner UI.

## Audit contract

Allow the audit action `fleet_student_registered` with entity type `student`. Task #10 writes it in the registration transaction with only safe metadata, such as `student_type` and `registration_origin`. Never include contact name, email, phone, address, coordinates, tokens, or request payloads.

## Migration and compatibility

- Create one new versioned migration with `supabase migration new prd_9_fleet_managed_student_model`; use the filename generated by the installed CLI and leave all applied migrations immutable.
- Backfill student origins and enrollment sources before enforcing `NOT NULL` or source-pairing constraints.
- Preserve the `fleet_enrollments` composite `(fleet_id, id)` key introduced by Cycle 3; use it for contact tenant integrity.
- Marketplace requests and invitation-originated requests that are later approved continue producing `join_request` enrollments. Accepting an invitation still creates a request; it does not create an enrollment.
- Existing active enrollment uniqueness, student creation behavior, and enrollment history remain intact.
- Owner registration creates neither a join request nor a guardian association for a pre-auth contact.

## Tests and acceptance criteria

Add a focused pgTAP file, expected next in sequence as `supabase/tests/database/045_fleet_managed_student_model.test.sql`. Follow RED → GREEN in small increments.

- Valid and invalid student type/origin/profile combinations are enforced.
- An owner-created adult is accepted with a null profile and remains valid when a profile is linked without changing its origin.
- `create_minor_student` still creates a `guardian_created` minor with no profile and its existing primary `student_guardians` row.
- `create_adult_student` still creates a `self_created` adult linked to `auth.uid()` and no guardian row.
- Existing SQL fixtures that insert students directly provide an explicit valid origin, including the denied-write case; do not add a generic default for `registration_origin`.
- Marketplace requests and invitation-originated requests later approved still produce `join_request` enrollments; accepting an invitation alone still produces only a request.
- Enrollment source/request mismatches fail; direct owner source with a null request succeeds; the active fleet/student uniqueness rule remains enforced.
- Updates that change a student's `registration_origin`, or an enrollment's `source_type` or `source_request_id`, fail; linking an owner-created adult's `profile_id` and updating unrelated fields still work.
- An `owner_registration` enrollment without `school_id` or `shift` fails at the database constraint.
- Contacts require a name and at least one contact method, allow multiple contacts, and allow only one primary contact per enrollment.
- Contact `updated_at` advances through the `private.set_updated_at()` trigger.
- Composite foreign-key tests reject an enrollment paired with the wrong fleet.
- RLS tests use at least two tenants and cover an authorized owner, same-tenant driver, guardian, and student, a different-tenant owner, and `anon`; direct client writes are denied.
- The model does not require synthetic requests or contact guardian links. The audit-action compatibility test accepts entity type `student`; Task #10 tests the real registration audit event and asserts its metadata contains only safe fields.
- The new `audit_events_action_valid` constraint preserves the full action list from the latest migration that defines it and adds `fleet_student_registered`; pgTAP verifies every pre-existing allowed action still passes, not just the new action.

## Local validation for implementation

Run the targeted pgTAP test through the local Supabase stack and confirm the RED failure is caused by the missing model behavior. Then run `supabase db reset`, the full `python3 supabase/tests/run_database_tests.py` suite, `supabase db lint --local --schema public,private --fail-on error`, `supabase db advisors --local --type all --fail-on error`, and `git diff --check`. No Flutter validation is needed for this database-only task; full Flutter and integrated scenario checks belong to Tasks #12 and #14.

The user authorized applying this task's migration remotely after local validation passes. Immediately before deployment, run `supabase --version`, `supabase db push --help`, and `supabase db diff --help`; use `--skip-vault` only if the installed CLI supports it and it is appropriate. Verify the linked project identity, inspect remote migration history and the dry-run, and confirm no unrelated pending migration would be applied. Apply only after those checks are clear. Verify the remote migration history before updating `deliverables.md`; after remote application, freeze this migration and put any correction in a new migration. Do not commit or push Git changes without separate authorization.

## References

- `CONTRIBUTING.md`, especially TDD, migration immutability, RLS, privacy, auditing, and validation requirements.
- `supabase/migrations/20260906201503_create_cycle_2_schema.sql` — current student and enrollment constraints.
- `supabase/migrations/20260906210854_create_student_functions.sql` — existing minor/adult creation behavior.
- `supabase/migrations/20260907235808_cycle_3_reservations.sql` — enrollment composite key and operational school/shift fields.
- `supabase/migrations/20260907235812_cycle_3_schedule_changes.sql` — schedule-change fallback to enrollment/request values.
- `supabase/migrations/20260907235815_cycle_4_calendar.sql` — latest migration defining the audit action allowlist; preserve its entries when adding the new action.
- `supabase/tests/database/011_students.test.sql` and `supabase/tests/database/014_enrollments.test.sql` — existing regression coverage.
