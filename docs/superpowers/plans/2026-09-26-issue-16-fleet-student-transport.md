# Fleet Student Transport Allocation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an authenticated owner atomically allocate and replace a fleet-managed student's explicit weekly transport program with durable receipts, revision control, and safe future-trip reconciliation.

**Architecture:** Extend the existing PostgreSQL planning system. Share locked validation and real execution-window rules with marketplace approval, keep request-specific behavior in its existing adapter, and store allocation receipts in a private table. Use the existing enrollment revision and an additive owner planning projection.

**Tech Stack:** PostgreSQL 17, Supabase CLI, PL/pgSQL, pgTAP, Python standard library and `psql` for real-session concurrency tests. No new dependencies.

**Spec:** [Approved Issue 16 design](../specs/2026-09-26-issue-16-fleet-student-transport-design.md).

## Global Constraints

- Applied migrations remain immutable. Implementation will use new migrations to replace only the affected function definitions and add allocation receipts.
- School is an assertion, not a change request.
- Use small RED -> GREEN -> Refactor cycles.
- All source, tests, comments, and technical documentation use US English; user-facing UI copy uses pt-BR.
- Do not reuse or update `registration_command_id`, `registration_payload_hash`, or registration provenance.
- The existing global lock is retained; replacing it with finer-grained locks is outside scope.
- Reservation changes, enrollment/trip revisions, passenger/stop changes, trip events, audit, and receipt insertion share one transaction.
- No production deployment, commit, or push is authorized by this plan. Commit checkpoints below require explicit authorization; otherwise keep the reviewed diff local.
- Run software-quality-gate before declaring implementation complete. Its tooling must remain outside the repository and must not install dependencies, create tests, or modify project configuration or lockfiles.

## Review Focus

1. A replay after B changed state, a cutoff elapsed, or school coverage changed must return A's receipt without reapplying A; current authorization still applies. Task 4.
2. Excluding the old seat must not also exclude a retained overnight occurrence from D-1. Task 1.
3. A removed weekday with a closed cutoff must block a full replacement even when every new day is still open. Task 2.
4. Reinstating a removed passenger must reuse semantic stops and must not revive a prior confirmation or an unrelated removal. Task 3.
5. Two write paths sharing a capacity helper must also share the lock through commit; one last seat and one expected revision cannot be consumed twice. Task 6.

## Execution setup and verification commands

Work in `/Users/victorpolonio123/.codex/worktrees/task-16-transport/vango-be` on `codex/task-16-fleet-student-transport`. Its inspected base is `935dd1a`. Confirm branch, current diff, and the presence of the #9/#10 migrations before editing. Preserve the original checkout and every other task's worktree.

Use a disposable local Supabase database exclusively owned by this execution. Worktrees share the default project ID/ports: a separate Git checkout does not isolate the database. If another task owns the default stack, run a temporary Supabase project/config outside the repository with its own project ID and free ports, copying this branch's migrations and seed. Set `VANGO_TASK16_DB_DIR` to that project root; otherwise set it to this worktree after verifying exclusive ownership. Do not reset a shared or remote database. Keep generated logs/SQL/config under a temporary directory outside the repository.

Before the first change, reset only that disposable target with `supabase db reset --local --workdir "$VANGO_TASK16_DB_DIR"` and record the baseline. After each migration change, synchronize its files into the external target if used, replay the migration history there, and run the focused suite. Never rewrite a migration applied outside this disposable development cycle.

Define this shell helper once; it reuses the repository's include-expansion implementation, including its path checks:

```sh
task16_tests() {
  VANGO_TASK16_TESTS="$*" python3 - <<'PY'
import os, runpy, subprocess, tempfile
from pathlib import Path
helpers = runpy.run_path('supabase/tests/run_database_tests.py')
sources = [Path('supabase/tests/database') / name
           for name in os.environ['VANGO_TASK16_TESTS'].split()]
with tempfile.TemporaryDirectory(prefix='vango-task16-tests-') as output:
    paths = []
    for source in sources:
        target = Path(output) / source.name
        target.write_text(helpers['expand_includes'](source))
        paths.append(str(target))
    subprocess.run(['supabase', 'test', 'db', '--local', '--workdir',
                    os.environ['VANGO_TASK16_DB_DIR'], *paths], check=True)
PY
}
```

For RED, start with one assertion for the behavior being added; require a TAP failure for that behavior, not an unrelated fixture, SQL syntax, or environment failure. A missing-function `has_function` assertion can establish the first RED; add behavioral assertions once the function exists. Repeat the cycle for each listed scenario rather than writing the entire acceptance matrix before implementation.

## File responsibilities

| File | Responsibility |
| --- | --- |
| `supabase/migrations/20260926190000_fleet_transport_shared_validation.sql` | Common locked allocation validation, direct-input normalization, and retained-window exclusion. |
| `supabase/migrations/20260926190100_fleet_transport_effective_dates.sql` | Request-independent cutoff predicate and compatible marketplace date adapter. |
| `supabase/migrations/20260926190200_fleet_transport_reconciliation.sql` | Safe removal/reinstatement with semantic stop reuse. |
| `supabase/migrations/20260926190300_fleet_transport_commands.sql` | Allocation receipt table, command RPC, revision behavior, and audit action. |
| `supabase/migrations/20260926190400_fleet_transport_projection.sql` | Owner-only enrollment revisions in the existing projection. |
| `supabase/tests/_fleet_transport.psql` | Focused fixtures and rollback/error assertions shared by the new tests. |
| `supabase/tests/database/047_fleet_transport_validation.test.sql` | Validation and retained-window regression. |
| `supabase/tests/database/048_fleet_transport_effective_dates.test.sql` | Explicit dates, timezones, cutoffs, protected executions. |
| `supabase/tests/database/049_fleet_transport_reconciliation.test.sql` | A-B-A, immutable snapshots, generation, stale route results. |
| `supabase/tests/database/050_fleet_transport_commands.test.sql` | Authorization, canonical replay, revision control, atomic rollback. |
| `supabase/tests/database/051_fleet_transport_projection.test.sql` | Revision visibility and projection compatibility. |
| `supabase/tests/concurrency/fleet_transport.py` | Real overlapping-session command/capacity/revision checks. |
| `supabase/tests/concurrency/fleet_transport_setup.psql`, `fleet_transport_cleanup.psql` | Committed race fixtures and narrowly scoped cleanup. |
| `README.md`, `be-tech-plan.md` | Published command contract, errors, scope, and validation instructions. |

Existing migration paths named in the spec are read-only references. Definitions are replaced by the new migrations above. Reserve these filenames only after checking that another integrated branch has not already used their migration versions/test numbers; resolve a collision before starting the first RED cycle.

### Task 1: Shared locked allocation validation

**Files:** Create the shared-validation migration, `_fleet_transport.psql`, and `047_fleet_transport_validation.test.sql`. Extend `020_reservations.test.sql` and `042_resource_release_timezone.test.sql` only for regressions directly caused by the extraction.

**Interfaces:**
- Consumes existing `private.lock_planning()`, `private.schedule_windows(uuid,date,date)`, capacity, student-conflict, set-conflict, and route-resource helpers.
- Produces `private.normalize_fleet_transport_allocations(p_allocations jsonb) returns jsonb`: strict direct-command shape, canonical typed/sorted triples.
- Produces `private.validate_transport_allocations(p_fleet_id uuid, p_student_id uuid, p_enrollment_id uuid, p_school_id uuid, p_shift text, p_allocations jsonb, p_effective_on date) returns jsonb`: lock, validate common resource/window rules, and return authoritative triples. A null enrollment supports the existing new-request path; it never grants access or creates enrollment/membership/request effects.
- Preserves the five-argument signatures of `private.reservation_has_capacity` and `private.student_schedule_conflicts`. Interpret their existing effective date as the boundary for excluding only superseded occurrences of the excluded enrollment.
- Test helper `pg_temp.seed_fleet_transport() returns void` extends `seed_cycle_3()` without altering it: add coordinates to its test school, register one minor and one unclaimed adult through #10, and put IDs plus initial revisions into a temporary `transport_case` row. Columns: `fleet_id`, `owner_id`, `second_owner_id`, `driver_id`, `foreign_owner_id`, `school_id`, `student_id`, `enrollment_id`, `adult_enrollment_id`, `going_schedule_id`, `return_schedule_id`, `initial_revision`, `command_a`, `command_b`, `effective_on`, `allocations`. Use ISO Monday after local tomorrow for `effective_on`; allocations are going weekdays 1/3 and return weekday 5. Commands are fixed distinct valid UUIDs ending `0016` and `0017` in an isolated fixture namespace.
- Test helper `pg_temp.fleet_transport_error(p_sql text) returns text` executes SQL under the caller's current role and extracts the structured domain code from a caught `PGRST` exception; rethrow unexpected SQLSTATEs. It must not be security-definer.

- [ ] **Step 1: Write the next failing test.** Establish the normalization contract, then add one validation behavior per cycle. Example assertions after seeding and calling the new normalizer:

```sql
select is(jsonb_array_length(private.normalize_fleet_transport_allocations(
  (select allocations from transport_case))), 3,
  'asymmetric explicit pairs stay three allocations');
select is(private.normalize_fleet_transport_allocations('[
 {"direction":"return","weekday":5,"schedule_id":"22222222-2222-4222-8222-222222222222"},
 {"direction":"going","weekday":1,"schedule_id":"11111111-1111-4111-8111-111111111111"}
]'::jsonb)->0->>'direction', 'going', 'canonical order is stable');
```

Add assertions that empty input, unknown/missing keys, weekday `1.5`, `0`, `8`, duplicate `(weekday,direction)`, invalid UUIDs, and forged directions yield `invalid_input`. Resource cases cover foreign schedules, inactive route/van/driver, wrong school/shift, unsupported weekday, and no actual remaining execution. Date/cutoff checks belong to Task 2.

- [ ] **Step 2: Run RED.** `task16_tests 047_fleet_transport_validation.test.sql`. Record the specific assertion failure before its production change.
- [ ] **Step 3: Implement only that behavior.** Extract common validation from `private.apply_request_allocation` into the declared helper. Acquire the common planning lock in the validation boundary. Keep marketplace's Cartesian completeness and request effects in its adapter; allow its existing optional direction input and canonicalize from the stored route. The direct normalizer still requires direction. Pass the same normalized selected triples to existing reservation writes.
- [ ] **Step 4: Add the retained-seat regression through another RED/GREEN cycle.** A full van remains available to its own replacing enrollment. For an old D-1 overnight occurrence overlapping a new D occurrence, `student_schedule_conflicts(...)` must be `true`; the capacity helper must count that retained occurrence. Exclude only windows with the old enrollment and service date on/after D. Preserve unrelated reservations and all distinct-student occupancy.
- [ ] **Step 5: Run GREEN and regressions.** `task16_tests 047_fleet_transport_validation.test.sql 020_reservations.test.sql 021_transport_queue.test.sql 022_schedule_changes.test.sql 042_resource_release_timezone.test.sql`. Expected: all TAP assertions pass; existing Cartesian marketplace approval still creates ten pairs for five weekdays/two directions.
- [ ] **Step 6: Review the diff and commit only if authorized.** Suggested commit: `refactor(planning): share locked transport allocation validation`.

### Task 2: Validate the exact requested effective date

**Files:** Create the effective-date migration and `048_fleet_transport_effective_dates.test.sql`; extend the focused fixture only as needed.

**Interfaces:**
- Consumes Task 1's authoritative triples and the existing calendar-aware schedule windows.
- Produces `private.transport_change_date_is_open(p_fleet_id uuid, p_enrollment_id uuid, p_allocations jsonb, p_effective_on date, p_now timestamptz) returns boolean`. It evaluates local date floor, schedule validity, first old/new executions, and persisted trip protection. Existing active assignments mean the next-local-day floor; no active assignments mean the local-current-date floor. No public clock override is introduced.
- Preserves both signatures of `private.next_change_date(uuid,timestamptz,jsonb)` and `private.next_change_date(uuid,timestamptz)`. Their search and marketplace exact-next-date contract remain intact; reuse the common predicate for each candidate.

- [ ] **Step 1: Write one failing time-boundary test.** Before creating reservations, configure fixture schedules with validity `2030-04-01` through `2030-05-31`, timezone `America/Sao_Paulo`, Monday route start `07:00`, and confirmation `30`. At `09:29:59+00` the first same-day allocation is open; at `09:30:00+00` it is closed. Public RPC tests later use dates safely relative to current time.

```sql
select is(private.transport_change_date_is_open(
  fleet_id, enrollment_id, allocations, date '2030-04-01',
  timestamptz '2030-04-01 09:29:59+00'), true,
  'first allocation is open immediately before cutoff') from transport_case;
select is(private.transport_change_date_is_open(
  fleet_id, enrollment_id, allocations, date '2030-04-01',
  timestamptz '2030-04-01 09:30:00+00'), false,
  'cutoff equality is closed') from transport_case;
```
- [ ] **Step 2: Run RED.** `task16_tests 048_fleet_transport_effective_dates.test.sql`. Expected: failure of the new predicate/cutoff behavior.
- [ ] **Step 3: Implement the predicate in the new migration.** Compare instants from `schedule_windows`, not server-local times. Return false for invalid/non-finite date, past local date, same-day replacement, invalid schedule-date intersection, missing actual new execution, elapsed first old/new cutoff, or protected affected materialized execution. Include old pairs absent from the replacement. Preserve D-1 overnight trips.
- [ ] **Step 4: Add boundary cases individually with RED/GREEN evidence.** Assert a safe later date is accepted without being rewritten; removing an old day whose cutoff is closed returns false even when new days pass; a manually closed future trip is rejected before its computed cutoff. Set session timezone to `UTC` and repeat with schedule timezones `America/Sao_Paulo` and `Pacific/Auckland` to prove local-date handling. Test an overnight execution, a schedule ending before D, a missing service day, and initiated/terminal executions on/after D. Trips before D are byte-for-byte unchanged.
- [ ] **Step 5: Wire marketplace candidate evaluation and run regressions.** `task16_tests 048_fleet_transport_effective_dates.test.sql 022_schedule_changes.test.sql 030_reconciliation.test.sql 042_resource_release_timezone.test.sql`. Expected: current marketplace next-date/queue behavior remains green. Do not relax its exact-next-date requirement to match the direct contract.
- [ ] **Step 6: Review and commit only if authorized.** `feat(planning): validate explicit allocation effective dates`.

### Task 3: Reconcile removal and reinstatement safely

**Files:** Create the reconciliation migration and `049_fleet_transport_reconciliation.test.sql`. Extend `030_reconciliation.test.sql` only for affected shared-helper regressions.

**Interfaces:**
- Preserves `private.reconcile_enrollment_trips(p_enrollment_id uuid, p_kind text, p_effective_on date, p_now timestamptz) returns integer`.
- Consumes persisted assignments/reservations, private generation helpers, existing trip events, and Cycle 6 input-hash checks. Produces consistent passenger/stop state and one revision/event per changed trip.

- [ ] **Step 1: Write the A-B-A regression before editing.** Materialize a future A trip, record its passenger ID and stop IDs, replace its reservation with B and reconcile, then restore A and reconcile, all before the deadline. Assert `removed_at is null`, the passenger ID is unchanged, and counts are one home stop per student, one school stop per school, and one passenger per enrollment/trip. This should fail on the current existing-association exclusion.

```sql
-- Store A's original row in a temporary original_passenger table before removal.
select is((select id from public.trip_passengers
           where trip_id = original.trip_id and enrollment_id = original.enrollment_id),
          original.id, 'reinstatement keeps passenger identity')
from original_passenger original;
select ok((select removed_at is null and confirmation_status = 'pending'
                  and confirmation_by is null and confirmation_at is null
                  and operation_status = 'waiting'
           from public.trip_passengers where id = original.id),
          'reinstatement is active and requires fresh confirmation')
from original_passenger original;
```
- [ ] **Step 2: Run RED.** `task16_tests 049_fleet_transport_reconciliation.test.sql`; record the reinstatement failure.
- [ ] **Step 3: Update only schedule reconciliation.** Reactivate only a schedule-superseded association in an unstarted, unclosed trip with operation `waiting`; reset confirmation to `pending` and actor/time to null. Reuse semantic stops before inserting missing ones. Preserve signature, address/school behaviors, started/terminal snapshots, and unrelated removal reasons. Increment revisions and emit an event only when state actually changes.
- [ ] **Step 4: Add no-op and negative cycles.** Repeat reconciliation and assert unchanged event counts/revisions/IDs. Confirm that ended-enrollment removals, boarded/absent/dropped-off operations, closed trips, and terminal trips are not reinstated. An earlier `confirmed` participation becomes `pending` when legitimately reintroduced. Compare snapshots for D-1 and started trips.
- [ ] **Step 5: Prove the generation/calculation boundary.** Use `private.generate_trips(date,timestamptz)` on a later service day and assert the restored reservations produce exactly one passenger. Exercise the existing route-calculation test pattern: a pre-reconciliation result cannot be applied to changed input. Prefer the existing input-hash guard; change it only if a reproducing test demonstrates a gap.
- [ ] **Step 6: Run GREEN and commit only if authorized.** `task16_tests 049_fleet_transport_reconciliation.test.sql 025_generation.test.sql 030_reconciliation.test.sql 040_route_revisions.test.sql`. Commit: `fix(planning): restore eligible future trip passengers`.

### Task 4: Atomic owner allocation command, receipts, and revisions

**Files:** Create the command migration and `050_fleet_transport_commands.test.sql`; extend `_fleet_transport.psql` for state snapshots and narrow failure injection.

**Interfaces:**
- Produces the exact public six-argument `assign_fleet_student_transport` and four-field result from spec section 3. Types/order must not drift.
- Produces `private.fleet_student_transport_commands(fleet_id uuid, command_id uuid, actor_user_id uuid, enrollment_id uuid, payload_hash bytea, routing_revision bigint, effective_on date, created_at timestamptz)`. All columns are non-null. Use the composite primary/foreign keys and immutability/access rules in spec section 5; hash length is 32 and revision is positive.
- Consumes Tasks 1-3. Advances `fleet_enrollments.routing_revision` exactly once per accepted new direct command and per existing marketplace schedule-change replacement.
- Test-only `pg_temp.fleet_transport_state(p_enrollment_id uuid) returns jsonb` produces a deterministically ordered snapshot of that enrollment, its assignments/reservations/receipts/audit, relevant trips/passengers/stops/events, and original registration fields. It is called as the test administrator, not exposed to API roles.

- [ ] **Step 1: Write the first command-contract RED.** Assert the six-argument RPC exists with the correct receipt columns. After its initial implementation, call with the fixture's three pairs and assert receipt `routing_revision = initial_revision + 1`, unchanged school, exactly three assignments/reservations, one allocation receipt/event, and no new join request, guardian, membership, or Auth row. Repeat with the unclaimed adult.

```sql
select has_function('public', 'assign_fleet_student_transport',
  array['uuid','uuid','jsonb','date','uuid','bigint'],
  'direct allocation publishes the approved command signature');
-- Once the command exists, execute this as the authenticated fixture owner.
select is(receipt.routing_revision, input.initial_revision + 1,
          'one command advances one enrollment revision')
from transport_case input
cross join lateral public.assign_fleet_student_transport(
  input.enrollment_id, input.school_id, input.allocations, input.effective_on,
  input.command_a, input.initial_revision) receipt;
```
- [ ] **Step 2: Run RED.** `task16_tests 050_fleet_transport_commands.test.sql`; require the intended missing contract/behavior failure.
- [ ] **Step 3: Implement the transaction.** Authenticate, acquire common planning lock before row locks, resolve enrollment/fleet, verify current owner and confirmed email, syntactically normalize, check receipt, compare expected revision, then validate new-command eligibility/school/resources/date. Capture server time after lock acquisition. Close old periods at D-1/cancel superseded future rows, insert new reservations, advance enrollment revision, reconcile, audit, save receipt, and return it. Use existing structured errors; unexpected exceptions become `allocation_failed`, never raw SQL details. Add the audit action without dropping any existing allowed actions. Revoke default/anonymous execution and direct helper/receipt access.
- [ ] **Step 4: Add authorization and validation cases through individual cycles.** Check the full spec error table: driver/foreign/unknown enrollment all yield `not_found`; unconfirmed email yields `email_unverified`; inactive enrollment/unsupported origin yields `invalid_transition`; school mismatch and null legacy fields yield `invalid_input`. Matching school with null/non-finite coordinates is rejected. Another authorized owner can allocate; no original-creator restriction. Snapshot state before/after each rejection.
- [ ] **Step 5: Implement and test canonical replay.** Hash version `1`, typed enrollment/school/date/expected revision, and sorted triples. Array/key order and UUID spelling normalization replay; changed actor or valid payload returns `idempotency_conflict`. Every receipt comparison follows current access validation and precedes mutable date/resource/revision checks. For malformed content, return `invalid_input`. Use the same ID in a second fleet to assert scope isolation.
- [ ] **Step 6: Pin delayed replay and failed-command behavior.** Apply A at revision 1 -> receipt 2, B at expected 2 -> receipt 3, then replay A with expected 1. Assert A returns revision 2 while current revision remains 3 and B's reservation IDs persist. Remove mutable school coverage or advance a private-test cutoff and assert authorized replay still returns its receipt; revoke the owner role and assert access denial. A new command with stale revision returns `revision_conflict`. A failed command has no receipt and can succeed later if its unchanged input becomes eligible.
- [ ] **Step 7: Pin replacement/history and legacy writers.** Assert pre-D rows and registration receipt/provenance remain identical; intersecting rows end D-1; future rows are cancelled with reason/timestamp; new pairs start D. A new command with identical desired content but a new ID/expected revision is a new accepted revision. Amend the marketplace replacement path to increment the same enrollment revision once; test a subsequent stale direct command and an address/school revision change. Preserve marketplace public results and queue semantics.
- [ ] **Step 8: Inject rollback failures separately.** In rollback-only tests, attach narrow test triggers that raise at reconciliation, allocation audit, and receipt insertion, respectively. Assert `allocation_failed` and `is(pg_temp.fleet_transport_state(id), before_state)` for each case. Remove each trigger in the same test transaction. Also fail the last pair on capacity and assert no partial replacement. Audit metadata must contain only command ID, effective date, allocation count, and previous/new revisions.
- [ ] **Step 9: Run GREEN and commit only if authorized.** `task16_tests 047_fleet_transport_validation.test.sql 048_fleet_transport_effective_dates.test.sql 049_fleet_transport_reconciliation.test.sql 050_fleet_transport_commands.test.sql 020_reservations.test.sql 021_transport_queue.test.sql 022_schedule_changes.test.sql 045_fleet_managed_student_model.test.sql 046_owner_fleet_student_rpcs.test.sql`. Commit: `feat(planning): allocate fleet students with durable command receipts`.

### Task 5: Publish the owner's enrollment revision projection

**Files:** Create the projection migration and `051_fleet_transport_projection.test.sql`. Update `README.md` and `be-tech-plan.md` with the approved public command and the added JSON key.

**Interfaces:**
- Preserves `public.get_fleet_planning(p_fleet_id uuid) returns jsonb`.
- Adds `enrollment_revisions: [{enrollment_id: uuid, routing_revision: bigint}]`, ordered by enrollment ID, for all active enrollments in an owner-authorized fleet, including those without allocations. Driver-only callers receive `[]`.
- Preserves `vans`, `routes`, `schedules`, `reservations`, and `revisions` and does not change `list_fleet_students` or `get_my_transport`.

- [ ] **Step 1: Write RED.** The owner sees the unallocated fixture's current revision, then sees `initial_revision + 1` after a successful command. An inactive enrollment is absent. Driver-only callers see `[]`; a foreign owner gets the existing inaccessible-fleet error. Compare all old projection keys to the pre-extension shape.

```sql
-- Run as the authenticated fixture owner, then repeat under the driver role.
select ok(exists (
  select 1 from jsonb_array_elements(
    public.get_fleet_planning(input.fleet_id)->'enrollment_revisions') item
  where item->>'enrollment_id' = input.enrollment_id::text
    and (item->>'routing_revision')::bigint = input.initial_revision
), 'owner sees revision before any allocation') from transport_case input;
-- Under the driver-only session:
select is(public.get_fleet_planning(fleet_id)->'enrollment_revisions',
          '[]'::jsonb, 'driver cannot read owner enrollment revisions')
from transport_case;
```
- [ ] **Step 2: Run RED.** `task16_tests 051_fleet_transport_projection.test.sql`. Expected: missing `enrollment_revisions` behavior.
- [ ] **Step 3: Add the owner-only array in a new function definition.** Reuse the function's existing owner authorization branch and preserve all other fields. It must coexist with #17's separately planned additive fields; integrate both definitions when those branches converge, without overwriting either extension.
- [ ] **Step 4: Document the consumer contract.** Explain command ID retention across retries, historical receipt versus current revision, school assertion, asymmetric pairs, complete replacement, date rules, errors, and no direct writes/generation. Describe actual local validation separately from remote rollout.
- [ ] **Step 5: Run GREEN and commit only if authorized.** `task16_tests 051_fleet_transport_projection.test.sql 023_planning_privacy.test.sql 046_owner_fleet_student_rpcs.test.sql`. Commit: `feat(planning): expose owner enrollment revisions`.

### Task 6: Prove cross-contract concurrency and release invariants

**Files:** Create the concurrency Python/setup/cleanup files in the file map. Update the new SQL suites only where a failing integrated invariant requires it; do not add general tooling.

**Interfaces:** `python3 supabase/tests/concurrency/fleet_transport.py` uses explicit local PostgreSQL environment variables and standard-library subprocesses to drive `psql`. Preserve the existing harness's local-host guard and reject `PGHOSTADDR`, service overrides, missing credentials, and nonlocal targets. No credential is printed. Cleanup targets only this run's fixture IDs in `finally`.

- [ ] **Step 1: Write one two-session check.** Use barriers and `pg_stat_activity` lock observation, not timing-only sleeps. Session A executes its command and holds the transaction; session B attempts the competing call; assert B is blocked on the planning protocol before committing A.
- [ ] **Step 2: Run the check against the prior behavior and record RED where applicable.** The new-command fixture establishes RED before command implementation; retain that evidence when composing this final harness. Do not invent a failure after the fix. Any newly uncovered race starts its own reproducing RED cycle before its correction.
- [ ] **Step 3: Implement each race assertion.** Last seat direct/direct: one success, one `capacity_exceeded`. Last seat direct/marketplace: one reservation and one winner in either acquisition order, with no older serviceable request confounding the fixture. Same command: identical receipts and one set of side effects. Distinct commands/same enrollment/same expected revision: one success and one `revision_conflict`. Distinct actors/same fleet command: one success and one `idempotency_conflict`. Test authenticated role sessions, not just administrator calls.

```python
# Capture structured results after releasing the observed lock barrier.
assert sorted(last_seat_outcomes) == ['capacity_exceeded', 'ok']
assert sorted(revision_outcomes) == ['ok', 'revision_conflict']
assert same_command_receipts[0] == same_command_receipts[1]
assert receipt_count == 1
assert allocation_audit_count == 1
```
- [ ] **Step 4: Run integrated verification.** Replay migrations from scratch on the disposable target, then use `task16_tests $(python3 -c 'from pathlib import Path; print(" ".join(p.name for p in sorted(Path("supabase/tests/database").glob("*.test.sql"))))')`. Run `supabase db lint --local --workdir "$VANGO_TASK16_DB_DIR"`, the new concurrency harness, existing `planning.py`, and `fleet_student_registration.py` against their supported disposable local targets. Expected: all assertions pass, no database lint errors, and exactly one winner in each conflict race. The existing registration harness requires port 54322; if a dedicated target differs, use a separate exclusively owned compatible instance rather than weakening its guard or claiming it ran.
- [ ] **Step 5: Run the software-quality-gate skill.** Capture Git status before/after; review the full diff, grants, empty search paths, error sanitization, atomicity, and critical conditions. Check `git diff --check`. No quality tooling or generated test output remains in the repository. Record unavailable checks and pre-existing baseline failures separately; do not declare the implementation complete with required gates outstanding.
- [ ] **Step 6: Review docs and commit only if authorized.** `test(planning): verify allocation concurrency and persistence`. No deployment or PR is implied.

## Self-review and handoff

Spec coverage: explicit pairs and shared locks -> Task 1; date/history boundaries -> Tasks 2/4; passenger reinstatement and route inputs -> Task 3; authentication, school assertion, idempotency, revisions, audit and rollback -> Task 4; read exposure -> Task 5; cross-contract concurrency and final evidence -> Task 6. All five Review Focus items have an owning test cycle. The catalog and #17 UI remain separate.

This plan is documentation only. No planned migration, test, or production function has been created. The user must review the plan and select an execution approach before implementation. Recommended: native execution with `superpowers:executing-plans`, because the SQL tasks share one transactional flow and overlapping function definitions; finish with an independent whole-branch review. Subagent-driven execution remains available if the user prefers a fresh implementer/reviewer per task.

## Execution evidence (2026-09-26)

Native execution was explicitly authorized after design approval. The disposable local database was rebuilt from all migrations: 53 pgTAP files and 1,076 assertions passed. Seven real-session races passed (identical replay, stale revision, actor mismatch, final seat, both marketplace orderings, and registration replay), with observed lock waits. Existing planning/resource concurrency regressions passed. The independent final review found three issues; compact stop insertion, historical removed associations, and effective-date classification were corrected with failing-then-passing regressions.

The quality gate found no unresolved correctness or security issue. Existing database lint warnings remain (including STABLE read RPCs calling the common error helper); no database lint errors. Complexity remains a warning in the existing reconciliation/allocation orchestration. No Flutter or Edge Function source changed. No production migration was applied. Catalog acquisition and the allocation UI remain separate deliveries.

Execution rulings: CLI-generated migration timestamps replace proposed names; isolated ports 563xx avoid the shared stack; the pre-existing test 046 TAP count was corrected from 65 to 66; commits are consolidated at task completion per user instruction; race cleanup drops only invocation-owned random databases without weakening immutable receipts; registration serialization is exercised on the isolated stack without changing the legacy harness's 54322 safety guard.
