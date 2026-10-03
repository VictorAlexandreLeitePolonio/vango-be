# Task 19 — Activate and verify daily trip materialization (handoff)

GitHub: issue #19 (parent epic #15). Read `AGENTS.md` and `CONTRIBUTING.md` first — they are binding.

## Workspace (do this first)

Another agent is working on task 20 (Flutter) in the main checkout at the same time. **Do not work in
`/Users/victorpolonio/Desktop/vango-be` directly.** Use an isolated worktree stacked on task 18:

```bash
cd /Users/victorpolonio/Desktop/vango-be
git worktree add ../vango-be-task-19 -b claude/task-19-daily-trip-materialization claude/task-18-assign-fleet-students
cd ../vango-be-task-19
```

- Branch base is `claude/task-18-assign-fleet-students` (tasks 9–18 are **not** on `main`). The PR, when the
  user authorizes it, targets `claude/task-18-assign-fleet-students`, not `main`.
- Never commit/push without explicit user authorization. Conventional Commits, en-US.
- Never run `supabase db push` or touch the remote project (`njjeopcxhnkeszukaoma`). Local stack only.
- The local Supabase stack (`supabase start`) is shared with the other agent; task 20 does not use the
  database, so `supabase db reset` is safe, but announce it to the user before running it.

## Scope decisions already made with the user

1. **Cron activation is versioned:** a new migration activates `vango-daily-operations`
   (`cron.alter_job(..., active := true)`), guarded so it is a no-op with a `raise notice` when `cron.job`
   does not exist. Real activation on the remote happens only when the user runs `db push` after the
   suite is green. Do not edit the applied migration `20260907235829_cycle_4_jobs.sql` (immutable).
2. Schedule stays `* * * * *` and the command stays
   `select private.run_daily_operations(clock_timestamp());` (generation is idempotent per schedule/date).
3. No Flutter changes. No new public RPC. `private.run_daily_operations` / `private.generate_trips` must
   remain non-executable by `authenticated` and `anon`.

## What already exists (read before writing tests)

| Thing | Where |
| --- | --- |
| `private.generate_trips(date, timestamptz)` — loops active `route_schedules`, inserts `service_days`, `trips` (`on conflict (schedule_id, service_date) do nothing`), `trip_assignments` (van/driver snapshot), `trip_passengers` from `transport_reservations` ⨝ `fleet_enrollments` (active, weekday, validity window), and `trip_stops` (origin, schools, `home` snapshots from `public.students`, destination) | `supabase/migrations/20260907235817_cycle_4_generation.sql` (~L200–380) |
| `private.run_daily_operations(timestamptz)` + cron job created **inactive** | `supabase/migrations/20260907235829_cycle_4_jobs.sql` |
| Direct owner allocation (task 16): `public.assign_fleet_student_transport(p_enrollment_id, p_school_id, p_allocations jsonb, p_effective_on, p_command_id, p_expected_routing_revision)`; `private.reconcile_enrollment_trips` updates not-yet-started trips | `supabase/migrations/20260926193617_fleet_transport_commands.sql`, `..._193538_fleet_transport_reconciliation.sql` |
| Fixtures: `pg_temp.seed_fleet_transport()` (fleet `41000000-…0001`, owner `40000000-…0001`, driver `…0003`, creates fleet-managed minor + adult students, next Monday in `v_day`, temp table `transport_case`) | `supabase/tests/_fleet_transport.psql` |
| Existing job test (asserts `active = false` today — must flip) | `supabase/tests/database/031_operation_jobs.test.sql` |
| Generation tests to mirror for style | `supabase/tests/database/025_generation.test.sql`, `050_fleet_transport_commands.test.sql` |
| Runbook to update | `docs/operations/ciclo-4-production.md` |

## TDD steps

### Step 1 — Red: regression test for direct allocations → generation

Create `supabase/tests/database/056_daily_trip_materialization.test.sql` (includes `../_helpers.psql`,
`../_planning.psql`, `../_operations.psql`, `../_fleet_transport.psql` as needed; wrap in
`begin; … rollback;`). Using `pg_temp.seed_fleet_transport()` + `assign_fleet_student_transport` as the
owner (JWT claims via `set_config('request.jwt.claims', …)`), then as `postgres` call
`private.generate_trips(<allocated service date>, <fixed now>)` and assert:

1. **Passengers:** the directly allocated fleet-managed student appears exactly once in `trip_passengers`
   for the trip of the allocated schedule/date; a student not allocated (or allocated to another
   weekday) does not appear.
2. **Idempotency:** calling `generate_trips` and `run_daily_operations` again does not change counts of
   `service_days`, `trips`, `trip_passengers`, `trip_stops`, `trip_assignments`.
3. **Timezone:** `planned_start_at = (service_date + starts_at) at time zone route_schedules.timezone`
   and `confirmation_deadline = planned_start_at - confirmation_minutes`. Include one case where the UTC
   date differs from the local date (e.g. `p_now` late evening `America/Sao_Paulo`) and assert
   `run_daily_operations` materializes the **local** tomorrow.
4. **Snapshots:** `trips.van_id/driver_user_id` and the `trip_assignments` row (`reason = 'generated'`)
   match the route at generation time; `home` stop `address_snapshot`/lat/lng match the student's
   address; school stop(s) present; origin position 1, destination 200000; going vs return ordering of
   home (1000+) vs school (100000+) positions follows `routes.direction`.
5. **Started trips are immutable:** start the generated trip as the driver (`public.start_trip`), then
   end/change the student's allocation via `assign_fleet_student_transport` (new effective date) and
   re-run generation; the active trip keeps its passenger and stops unchanged, while a later
   not-started trip reflects the change.
6. **Tenant isolation:** a second fleet's schedule/allocation never produces passengers in the first
   fleet's trips (every table touched carries `fleet_id`; assert `trip_passengers.fleet_id = trips.fleet_id`).
7. **Privileges:** `authenticated` and `anon` lack EXECUTE on `private.generate_trips` and
   `private.run_daily_operations`.

Run: `supabase test db --local` via the runner (single file needs include expansion):
`python3 supabase/tests/run_database_tests.py` (or temporarily expand). Confirm which assertions fail
and **why**. If they all pass on first run, that is legitimate for a regression suite — record it; only
fix generation if a real defect shows up (then a new migration with `create or replace`).

### Step 2 — Red: job must be active

In `031_operation_jobs.test.sql`, change the assertion
`'job diário nasce inativo para revisão operacional'` to expect `true` with description
`'daily operations job is active after the versioned rollout'`. Run → fails.

### Step 3 — Green: activation migration

`supabase migration new activate_daily_operations_job` →
`supabase/migrations/<timestamp>_activate_daily_operations_job.sql`:

```sql
-- Activates the daily operations job created inactive by cycle 4. Versioned so the
-- remote rollout is reproducible; it only takes effect when the operator runs db push.
do $activate$
declare
  v_job_id bigint;
begin
  if to_regclass('cron.job') is null then
    raise notice 'pg_cron not available; daily operations job left untouched';
    return;
  end if;
  select jobid into v_job_id from cron.job where jobname = 'vango-daily-operations';
  if v_job_id is null then
    raise exception 'vango-daily-operations job is missing';
  end if;
  perform cron.alter_job(v_job_id, active := true);
end;
$activate$;
```

`supabase db reset` (local) → full suite green.

### Step 4 — Runbook

Update `docs/operations/ciclo-4-production.md` (keep its Portuguese prose): job is now activated by the
new migration; pre-`db push` gate = full pgTAP suite + concurrency `operations.py` green; how to inspect
state and latest runs:

```sql
select jobid, jobname, schedule, command, active from cron.job where jobname = 'vango-daily-operations';
select status, return_message, start_time, end_time
from cron.job_run_details
where jobid = (select jobid from cron.job where jobname = 'vango-daily-operations')
order by start_time desc limit 10;
```

plus how to deactivate in an incident (`cron.alter_job(<jobid>, active := false)` — and that the
permanent change must be a new migration). Also tick the relevant line in `README.md`/`deliverables.md`
only for what was actually executed.

## Verification gate (record actual output in the final report)

```bash
supabase db reset
python3 supabase/tests/run_database_tests.py
supabase db lint --local --schema public,private --fail-on error
PGHOST=127.0.0.1 PGPORT=54322 PGDATABASE=postgres PGUSER=postgres PGPASSWORD=postgres \
  python3 supabase/tests/concurrency/operations.py   # check the script header for its expected DB/setup
git diff --check
git status
```

## Acceptance criteria (issue #19)

- [ ] Direct allocations generate correct daily passengers (test 056).
- [ ] Repeated execution remains idempotent.
- [ ] Cron/job state is explicitly configured (migration) and documented (runbook).
- [ ] Next service-day trips are materialized without any Flutter insert.
- [ ] Database suite, concurrency tests and lint pass.

## Out of scope

Flutter, notifications, `db push`, editing applied migrations, changing the cron schedule, exposing any
private function.
