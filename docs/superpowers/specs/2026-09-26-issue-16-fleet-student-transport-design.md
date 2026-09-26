# Issue 16: Fleet Student Transport Allocation Design

**Status:** Approved by the user for implementation planning on 2026-09-26; implementation is not authorized.
**Date:** 2026-09-26
**Issue:** [#16](https://github.com/VictorAlexandreLeitePolonio/vango-be/issues/16), part of [PRD #15](https://github.com/VictorAlexandreLeitePolonio/vango-be/issues/15).
**Branch:** `codex/task-16-fleet-student-transport`.
**Inspected base:** `935dd1a`, containing the #9 model and #10 owner registration contracts.

## 1. Outcome and scope

An active fleet owner assigns an already registered fleet-managed student to real transport schedules. A command replaces the enrollment's entire transport program from an explicit service date, atomically, without creating a marketplace request, enrollment, Auth account, guardian relationship, or role grant.

The user approved explicit, asymmetric day/direction combinations; complete replacement from the chosen date; and preservation of earlier history. Their subsequent review requires allocation-specific idempotency, optimistic revision checks, shared locking and capacity rules, operational cutoff validation, and removal/reinstatement of passengers in future trips.

This delivery changes database contracts and their tests. Flutter allocation UI belongs to #18. Van/route/schedule UI belongs to #17. Catalog loading, school changes with future effect, suspension of all transport, trip-job rollout, GPS, and new marketplace functionality are outside #16.

## 2. Existing contracts and concrete gaps

| Source | Relevant behavior |
| --- | --- |
| `supabase/migrations/20260924105909_prd_10_registration_replay_after_coverage_change.sql` | `create_fleet_managed_student` requires a served school and a shift and persists both on the enrollment. Registration receipts describe the original registration only. |
| `supabase/migrations/20260907235808_cycle_3_reservations.sql` | `private.apply_request_allocation` mixes request-specific completeness, allocation validation, reservation writes, and marketplace effects. Existing capacity and conflict helpers compare real execution windows. |
| `supabase/migrations/20260907235812_cycle_3_schedule_changes.sql` | `private.next_change_date` checks old and new executions, local schedule dates, and confirmation deadlines. Marketplace approval requires its calculated next date. School/address commands already advance enrollment routing revisions. |
| `supabase/migrations/20260907235827_cycle_4_reconciliation.sql` | A school update reconciles from `current_date`. Schedule reconciliation removes passengers but its insertion query skips an association that exists with `removed_at` set. |
| `supabase/migrations/20260907235814_cycle_3_projections.sql` | `get_fleet_planning` exposes route revisions, but not enrollment revisions needed for owner allocation edits. |
| `supabase/migrations/20260907235846_cycle_6_route_revisions.sql` | Route calculation results depend on passenger/stop input. Reconciliation must not leave an old calculation applicable to changed input. |

Applied migrations remain immutable. Implementation will use new migrations to replace only the affected function definitions and add allocation receipts. No production code changes are included in this document.

## 3. Public command and read contract

Proposed first published signature:

```sql
public.assign_fleet_student_transport(
  p_enrollment_id uuid,
  p_school_id uuid,
  p_allocations jsonb,
  p_effective_on date,
  p_command_id uuid,
  p_expected_routing_revision bigint
) returns table (
  command_id uuid,
  enrollment_id uuid,
  routing_revision bigint,
  effective_on date
)
```

The result is a one-row immutable receipt. `routing_revision` is the enrollment revision produced by this command, not necessarily its current revision when an old receipt is replayed. This extends the issue's proposed UUID-only response before the RPC has consumers.

Each allocation has exactly these required keys:

```json
[
  {"schedule_id": "11111111-1111-4111-8111-111111111111", "weekday": 1, "direction": "going"},
  {"schedule_id": "11111111-1111-4111-8111-111111111111", "weekday": 3, "direction": "going"},
  {"schedule_id": "22222222-2222-4222-8222-222222222222", "weekday": 5, "direction": "return"}
]
```

This produces three assignments and three reservations, not a six-item Cartesian product. Weekdays use ISO values, Monday `1` through Sunday `7`. Every day/direction pair occurs at most once. Duplicate objects, duplicate pairs referencing different schedules, missing/unknown keys, invalid UUIDs, fractional weekdays, unknown directions, nulls, and empty arrays are rejected. Empty input does not suspend transport.

Extend `get_fleet_planning(p_fleet_id)` additively with `enrollment_revisions`: an array of `{enrollment_id, routing_revision}` for active enrollments in that fleet when the caller is an owner. Return an empty array to driver-only callers. Preserve existing keys and their meaning. Include unallocated enrollments so a first command can use an authoritative revision. Do not alter the table-returning `list_fleet_students` contract.

## 4. Access, school, and allocation validation

Resolve the fleet and student from the enrollment; neither is supplied as an authoritative client parameter. Require authentication, confirmed email, and a current active owner membership in that fleet. Recheck access inside the common planning lock. Unknown or inaccessible enrollment IDs return the same `not_found` response, including for driver-only and cross-fleet callers.

For a new command, require an active enrollment with `source_type = 'owner_registration'` and its existing student with `registration_origin = 'fleet_owner_created'`. The inspected `students` schema has no lifecycle status; active transport eligibility comes from the enrollment, and this task does not invent a student status field. Do not require the allocating owner to be the original registering owner. Both minors and adults without an Auth profile are supported.

**School is an assertion, not a change request.** `p_school_id` must equal the enrollment's existing, non-null school. The school must be active, served by this fleet, and have finite coordinates within valid latitude/longitude ranges. Routes must serve that school. The enrollment's persisted shift must match every selected route's shift. This command never updates `school_id` or `shift`, including for a future effective date. An incomplete legacy enrollment is rejected rather than silently initialized.

The #10 registration contract already supplies school and shift. The `current_date` school-reconciliation trigger therefore does not need to run or change for #16. Scheduling a future school transfer requires a separate effective-dated design. Administrative correction of catalog coordinates is unrelated to that feature.

Validate each schedule, route, van, and assigned driver against current backend state: same fleet, active status/driver membership, school, shift, weekday support, and date validity. The route's stored direction is authoritative; a client direction mismatch is an error. A selected weekday must have at least one actual service execution within the schedule's remaining validity. Reuse calendar-aware execution windows and resource checks rather than approximating them with weekday or local-time equality.

## 5. Idempotency and optimistic concurrency

Add a private, allocation-specific receipt table, `private.fleet_student_transport_commands`, containing:

- `fleet_id`, `command_id`, `actor_user_id`, and `enrollment_id`;
- a SHA-256 hash of the normalized command payload;
- the applied `routing_revision`, `effective_on`, and server `created_at`.

Use `(fleet_id, command_id)` as the primary key, a composite enrollment/fleet foreign key, positive-revision and finite-date checks, and a 32-byte hash check. Preserve actor identity and enrollment references with restrictive deletion behavior. Keep the table outside exposed schemas, enable RLS, and revoke direct client reads/writes. Receipts are immutable and are not expired by this task. Do not reuse or update `registration_command_id`, `registration_payload_hash`, or registration provenance.

Canonicalize only syntactically valid input: typed UUIDs, integer weekdays, exact direction values, ISO date, and positive expected revision. Sort allocations by weekday, direction, and schedule UUID. JSON key ordering and allocation ordering do not change identity. Reject duplicates instead of deduplicating them. Hash a versioned JSON object containing enrollment, school, allocations, effective date, and expected revision. Compare actor separately. Do not include mutable route/school attributes in the hash or require mutable eligibility to reconstruct a valid replay.

After access validation and locking, apply this order:

| Condition | Result |
| --- | --- |
| Receipt exists; same actor and canonical payload | Return its original result before checking current revision, date, capacity, or resource eligibility. Write nothing. |
| Receipt exists; different actor or valid canonical payload | `idempotency_conflict` after access validation. |
| No receipt; expected revision differs from current enrollment revision | `revision_conflict`; write nothing. |
| No receipt; expected revision matches | Validate and apply a new command, increment the revision once, and store its receipt atomically. |

Access revocation or loss of email confirmation blocks even a replay. Later enrollment deactivation or student-detail changes do not turn an authorized receipt replay into a second allocation. Malformed input returns `invalid_input` without exposing a receipt. An identical UUID in another fleet is a separate command and reveals nothing about this fleet.

The sequence A applied, B applied, delayed A replay returns A's historical receipt and leaves B's state untouched. A failed transaction leaves no receipt. Retrying a failed command evaluates it again against current state.

Reuse `fleet_enrollments.routing_revision`; do not introduce a parallel allocation version. Accepted new commands increment it exactly once, including a new command that repeats the same desired program. All existing paths that replace the same enrollment's recurring allocations must also advance this revision once. In particular, cover the existing marketplace schedule-change path without changing its signature, return value, queue rules, or Cartesian completeness rule. Existing school/address revision changes also invalidate stale allocation edits.

## 6. Effective date and protected executions

`p_effective_on = D` is a service date interpreted separately in each affected schedule's IANA timezone. Never replace it with a calculated date silently or use the database timezone as a substitute for a schedule timezone.

For a first allocation, D may be the local current date if all affected executions remain open. For replacement of existing assignments, preserve the existing schedule-change lower bound: D is at least the next local date in every affected schedule timezone. This intentionally keeps same-day initial setup distinct from replacing an existing program. Both cases reject retroactive dates and require D within every new schedule's finite validity interval.

Unlike marketplace approval, the direct contract accepts a later safe date; it need not equal the earliest safe date. Keep marketplace's exact-next-date rule unchanged. Factor the underlying execution/cutoff checks so both paths use the same protection; do not call a request-dependent helper with a fabricated request.

Under the planning lock, capture server time and examine the affected old and new execution windows using `private.schedule_windows`:

1. For each proposed allocation, examine its first actual service execution on or after D. Require server time strictly before start minus `confirmation_minutes`.
2. For every old assignment being shortened or cancelled, perform the same check on its first actual execution on or after D, even if its day/direction is absent from the new list. Bound old execution dates by that assignment's own validity.
3. For affected materialized trips, also respect persisted `confirmation_deadline`, explicit closure state, `started_at`, and terminal state. A persisted closed execution cannot be made editable by changing a schedule or passing an earlier clock comparison.
4. Reject a replacement that would change participation in an already protected execution on or after D. Preserve executions before D, including an overnight trip whose service date is D-1.

Use `effective_date_conflict` for an unavailable requested date or protected execution. A schedule that does not support the requested allocation returns `invalid_input`. An unchanged desired pair does not exempt a complete replacement from cutoff checks. Receipt replay remains a read and bypasses these mutable checks after current authorization succeeds.

A successful replacement keeps earlier rows whose validity ends before D unchanged; shortens intersecting active rows to D-1; and cancels active rows starting on/after D with timestamp and reason. Apply the same boundaries to `route_student_schedules` and `transport_reservations`. Never delete their history. Insert each new pair with `valid_from = D` and `valid_until = schedule.valid_until`.

## 7. Shared validation and locking

Use the existing transaction-scoped `private.lock_planning()` protocol before request/enrollment, student, schedule, van, or trip row locks. Keep stable ordering for rows of the same kind and retain the lock through validation, writes, reconciliation, audit, and receipt insertion. The existing global lock is retained; replacing it with finer-grained locks is outside scope.

Extract only common allocation validation from `private.apply_request_allocation`. Reuse `private.reservation_has_capacity`, `private.student_schedule_conflicts`, `private.allocation_set_conflicts`, and the route resource rules. The common write-path validation boundary must acquire/reacquire the same planning lock; callers must not release it between a capacity check and its write. Read-only queue previews remain previews and never replace locked checks during approval.

The marketplace adapter retains requested `directions × weekdays` completeness, queue priority, request transitions, initial enrollment creation, guardian/student membership effects, and existing public behavior. The direct adapter passes explicit pairs and an existing enrollment and performs none of those request effects.

When checking a replacement, exclude only the old occurrences superseded from D onward. The student's own old seat must not count as a second passenger. Retained occurrences before D remain relevant if their real overnight windows overlap a new occurrence. The current helpers exclude an entire enrollment; refine that exclusion where necessary and regression-test both callers. Capacity and student-conflict checks must include that retained boundary and use actual time windows.

Two owners editing one enrollment from the same revision cannot both succeed. A direct allocation and a marketplace approval for different students contending for the same last seat cannot both succeed. Holding the common lock is essential to both guarantees; a preliminary query alone is insufficient.

## 8. Reconciliation and atomic side effects

Call `private.reconcile_enrollment_trips(enrollment_id, 'schedule', D, server_time)` after replacing reservations. It reconciles already materialized, editable future trips; it does not expose or invoke daily generation as a shortcut. Later generation consumes the new persisted reservations normally.

Preserve the existing reconciliation signature and non-schedule behaviors. For schedule reconciliation:

- Mark a passenger removed when the new reservations no longer cover that execution.
- Insert a passenger only when no association exists.
- If the same trip/enrollment association was removed by an earlier schedule replacement and is eligible again, reuse its ID and clear removal fields. Do not revive removals caused by ending an enrollment or another operational action.
- Reinstatement requires an unstarted, unclosed execution with no passenger operation already performed. Set confirmation to `pending`, clear confirmation actor/time, and keep operation status `waiting`; a removed participation does not silently recover an earlier confirmation.
- Reuse the existing home stop for that student and school stop for that institution. Insert only missing semantic stops, preserving valid ordering. A-B-A must not duplicate passengers or stops. Refresh editable snapshots if necessary before the trip starts.
- Preserve initiated/completed trip snapshots, passenger operations, and historical events. The command rejects affected protected executions; the helper retains its own safe state guards.
- Advance each changed trip's revision and append its reconciliation event once per actual change. Preserve the Cycle 6 input-hash/revision protections so a pre-change route calculation cannot be applied to a changed passenger/stop set. Do not add a route provider or calculate routes in this RPC.

Write one sanitized allocation audit event, `fleet_student_transport_assigned`, for each accepted new command, associated with the enrollment. Metadata is limited to command ID, effective date, allocation count, and previous/new revisions. Do not log names, contacts, addresses, coordinates, raw input, or another fleet's details.

Reservation changes, enrollment/trip revisions, passenger/stop changes, trip events, audit, and receipt insertion share one transaction. A failure in any stage rolls back all of them. Historical receipts remain immutable and original registration receipts/provenance remain untouched.

## 9. Error contract and exposure

Use the existing structured `private.raise_api_error` convention. Clients consume domain codes, not SQL messages.

| Code | HTTP status | Meaning |
| --- | --- | --- |
| `unauthenticated` | 401 | No authenticated actor. |
| `email_unverified` | 403 | Actor's email is not confirmed. |
| `not_found` | 404 | Enrollment is missing or inaccessible as an owner. |
| `invalid_input` | 400 | Malformed input, school assertion mismatch, invalid references/coordinates, incomplete enrollment, or incompatible allocation. |
| `invalid_transition` | 409 | New command targets an inactive enrollment or an unsupported enrollment/student origin. |
| `idempotency_conflict` | 409 | Existing fleet-scoped command belongs to another actor or payload. |
| `revision_conflict` | 409 | New command was based on a stale enrollment revision. |
| `effective_date_conflict` | 409 | Requested date violates date/cutoff/protected-execution rules. |
| `capacity_exceeded` | 409 | Any requested execution lacks a seat. |
| `schedule_conflict` | 409 | Student, allocation set, or assigned resources conflict. |
| `allocation_failed` | 500 | Unexpected failure, without raw SQL details. |

Public RPC privileges follow the existing authenticated owner-command pattern, with explicit grants/revokes and safe empty `search_path` for privileged functions. Allocation helpers and receipts remain private; clients receive no direct planning-table write permission. Existing errors from unaffected marketplace operations retain their current contracts.

## 10. Required test evidence

Use small RED -> GREEN -> Refactor cycles. The following are acceptance scenarios, not claims of tests already executed.

| Area | Required assertions |
| --- | --- |
| Valid direct allocation | Minor and unclaimed adult work; the three asymmetric example pairs produce exactly three assignments/reservations. No join request, guardian, Auth account, or membership is created. |
| Authorization | Anonymous, unconfirmed, inactive owner, driver-only, foreign enrollment UUID, and mixed-fleet schedule fail. Authorized non-creator owner succeeds. Every tenant-bearing object is tested with two fleets. |
| Input | Reject empty list, nulls, duplicate pair/object, fractional/out-of-range weekday, forged direction, unsupported school/shift, unavailable van/driver, invalid coordinates, and non-finite date. All failed calls preserve state. |
| School assertion | Matching school succeeds; another school fails without updating the enrollment or pre-D trips. Null legacy school is not initialized implicitly. |
| Receipt identity | Array/key reordering and UUID normalization replay one receipt. Changed actor, enrollment, date, allocation, or expected revision conflicts under the same fleet command ID. No receipt leaks across fleets. |
| Replay order | A -> B -> delayed A returns A's saved revision/date without undoing B. Replay still works after mutable cutoff/resource changes while current owner access remains; revoked access blocks it. |
| Revision | Two distinct commands based on one revision produce one success and one `revision_conflict`. Address/school and legacy allocation changes also make a stale direct command fail. The owner projection supplies the revision; driver-only projection does not. |
| Replacement | Preserve periods before D, close intersecting rows at D-1, cancel future rows, and insert complete new pairs. Do not change registration receipt or provenance. |
| Effective date | Cover first-allocation same-day-before-cutoff, replacement same-day rejection, safe later date, exact cutoff equality, differing server/schedule timezones, overnight windows, and a removed old day whose cutoff has closed. No automatic date shift. |
| Protected trips | Reject mutations affecting a closed/started/terminal execution on/after D; preserve earlier executions and overnight D-1 snapshots. Unstarted alone does not imply editable. |
| Own seat | An enrollment occupying the last seat can retain that seat on replacement. Its retained overnight pre-D assignment still participates in overlap checks. |
| Capacity and conflicts | A failure on one pair rolls back every pair. Test real overlapping windows across schedules, resources, and student enrollments. |
| Real-session races | Direct/direct and direct/marketplace competition for the final seat yield exactly one allocation; run both acquisition orders. Same-command concurrent calls return one receipt. Same-enrollment distinct-command race produces a revision conflict. |
| Reconciliation | Future A -> B -> A restores the original passenger ID, leaves one semantic home/school stop, resets confirmation as specified, and preserves unrelated removals/operational states. Repetition adds no events or revisions. |
| Generation and calculation | Already materialized trips reconcile; later materialization consumes reservations without duplicates. A route result calculated before a changed passenger set cannot be applied afterward. |
| Atomicity and privacy | Inject failure during reconciliation/audit/receipt persistence and compare all affected tables and revisions with their starting state. Audit/receipt data contains no address/contact/coordinate payload. |
| Regression | Existing marketplace completeness, queue priority, guardian/self enrollment, school/address change, reconciliation, resource-window, and owner-registration suites still pass. |

Primary existing test references are `020_reservations.test.sql`, `021_transport_queue.test.sql`, `022_schedule_changes.test.sql`, `023_planning_privacy.test.sql`, `025_generation.test.sql`, `030_reconciliation.test.sql`, `040_route_revisions.test.sql`, `042_resource_release_timezone.test.sql`, and `046_owner_fleet_student_rpcs.test.sql` under `supabase/tests/database/`. Follow the existing real-session harness under `supabase/tests/concurrency/`; use only a disposable local database and deterministic synchronization barriers.

## 11. Implementation boundaries and completion evidence

Implementation will add migration(s), focused pgTAP coverage, and allocation concurrency coverage. It may replace only the relevant shared allocation/date/reconciliation functions and extend the owner planning projection. Update the repository README and backend contract documentation in English. All future Flutter UI copy remains pt-BR. Do not introduce Node.js, another transport model, dependencies, public cron access, or a general command framework.

The implementation plan is [Issue 16 Implementation Plan](../plans/2026-09-26-issue-16-fleet-student-transport.md). Before implementation is declared complete, rebuild a disposable local database from the migration history, run focused tests and the complete database suite through `python3 supabase/tests/run_database_tests.py`, run real-session concurrency checks, run `supabase db lint --local`, and inspect `git diff --check`. Run the software-quality-gate skill with Git status before and after; it must not install dependencies, create tests, or change project configuration/lockfiles. Report unavailable checks rather than claiming success. Flutter/Deno validation applies if their source is changed; neither is planned in #16.

The user subsequently authorized native implementation, commit, and push for both task branches. Do not edit unrelated work in the original checkout.

## 12. Related #17 decisions retained for its separate specification

The user approved a real catalog covering schools and higher-education campuses throughout Sao Paulo state, filtered by cities served by the fleet. Public and private institutions are included. Coordinates must be validated before an institution appears as available; administrative correction is permitted when automatic matching fails. Loading and verifying that catalog is a separate prerequisite for #17, not part of this allocation migration. The ingestion source, geographic coverage evidence, and coordinate-validation workflow still need their own concrete design; existing database support is not proof that real catalog data has been loaded.

#17 will configure vans, routes, schedules, and explicit owner-as-driver readiness through existing backend contracts. #18 will consume this allocation command and preserve its command ID and expected revision across retries. No implementation or specification approval for those deliveries is inferred from approval of #16.

## 13. Review status

This specification incorporates the user's five review areas and records explicit decisions for school immutability, normalized idempotency, revision exposure, date boundaries, locking, and reinstatement. The user approved it for planning and also requested an initial design/specification for #17. No migration, production source, automated test, or remote database was changed while preparing these documents; no runtime validation is claimed.

## Execution evidence (2026-09-26)

Native execution was explicitly authorized after design approval. The disposable local database was rebuilt from all migrations: 53 pgTAP files and 1,076 assertions passed. Seven real-session races passed (identical replay, stale revision, actor mismatch, final seat, both marketplace orderings, and registration replay), with observed lock waits. Existing planning/resource concurrency regressions passed. The independent final review found three issues; compact stop insertion, historical removed associations, and effective-date classification were corrected with failing-then-passing regressions.

The quality gate found no unresolved correctness or security issue. Existing database lint warnings remain (including STABLE read RPCs calling the common error helper); no database lint errors. Complexity remains a warning in the existing reconciliation/allocation orchestration. No Flutter or Edge Function source changed. No production migration was applied. Catalog acquisition and the allocation UI remain separate deliveries.

Execution rulings: CLI-generated migration timestamps replace proposed names; isolated ports 563xx avoid the shared stack; the pre-existing test 046 TAP count was corrected from 65 to 66; commits are consolidated at task completion per user instruction; race cleanup drops only invocation-owned random databases without weakening immutable receipts; registration serialization is exercised on the isolated stack without changing the legacy harness's 54322 safety guard.
