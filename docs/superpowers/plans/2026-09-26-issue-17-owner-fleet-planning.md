# Issue 17 Owner Fleet Planning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an authenticated fleet owner persist coverage, vans, operators, routes, and schedules through independent forms with atomic retries and stale-edit protection.

**Architecture:** Extend existing Supabase planning functions and their integrated projection. Flutter uses a typed domain service and one context-scoped controller; widgets never write tables directly. Catalog acquisition remains an independent prerequisite.

**Tech Stack:** Existing PostgreSQL/Supabase/PostgREST, pgTAP, Python concurrency harness, Flutter/Dart, Material, flutter_map and latlong2. No new runtime dependency.

**Spec:** [Consolidated Issue 17 design](../specs/2026-09-26-issue-17-owner-fleet-planning-design.md).

## Global Constraints

- Independent entity forms; explicit point confirmation; explicit owner-driver action; no student allocation or trip generation.
- English code, tests, comments, and technical documentation; pt-BR user-facing copy.
- Strict RED -> GREEN -> Refactor, one behavior at a time. Record actual failing assertions and subsequent passing commands; do not manufacture RED for already-correct behavior.
- Existing signatures remain compatible. New overloads require command ID and expected revision without defaults. Creation sends explicit null entity ID/revision; editing sends both nonnull.
- `edit_revision` is positive and monotonic, independent of `routing_revision`; do not promise an increment of exactly one per command.
- Van capacity `1..100`; proximity `1..60`, default `10`; ISO weekdays `1..7`; confirmation minutes `0..1440`; default timezone `America/Sao_Paulo`; explicit validity dates and overnight flag.
- Public/private schools and higher-education campuses throughout SP, including interior municipalities; only published institutions with validated finite coordinates may be selected.
- Reuse existing validation, planning lock, audit behavior, map components, authentication, and registration retry patterns. No parallel role system or general command framework.
- Preserve unrelated work. Commits/pushes require separate explicit authorization under CONTRIBUTING.md; all commit checkpoints below are conditional.
- Native implementation and commit/push are authorized. Integrated base: `a3d57d2` (#12/#13 plus #16). Catalog fixtures do not establish real statewide coverage.

## Review Focus

1. Legacy updates between opening and submitting a form invalidate its expected revision (Task 2).
2. Direct coverage deletion races with school linking or route creation and must never leave an invalid relation (Task 1/4).
3. Lost responses followed by role removal or another edit must not let an old replay mutate current state (Task 3/6).
4. Added nested projection keys are accepted, but malformed known values and PostgreSQL time strings are handled deliberately (Task 5).
5. Map loading without explicit selection, large text, and session changes during a submission must not save a default point or cross-fleet draft (Task 6/7).

## File and dependency map

All paths are relative to the #17 worktree. Check migration/test number collisions after integration; if occupied, rename the proposed new files consistently before writing them.

| Deliverable | Files to create or modify |
| --- | --- |
| Coverage invariants | `supabase/migrations/20260926200000_fleet_planning_coverage.sql`; `supabase/tests/052_fleet_planning_coverage.test.sql`; `supabase/tests/_fleet_planning.psql` |
| Edit versions | `supabase/migrations/20260926200100_fleet_planning_edit_revisions.sql`; `supabase/tests/053_fleet_planning_edit_revisions.test.sql` |
| Commands/role adapter | `supabase/migrations/20260926200200_fleet_planning_commands.sql`; `supabase/tests/054_fleet_planning_commands.test.sql` |
| Projection | `supabase/migrations/20260926200300_fleet_planning_projection.sql`; `supabase/tests/055_fleet_planning_projection.test.sql` |
| Real integration checks | `supabase/tests/concurrency/fleet_planning.py`; `supabase/tests/http/fleet_planning.py` |
| Flutter models/service | `vango_app/lib/features/fleet/models/fleet_planning.dart`; `models/fleet_planning_commands.dart`; `services/fleet_planning_service.dart`; `services/fleet_planning_error_mapper.dart` under the same feature root |
| State | `vango_app/lib/features/fleet/controllers/fleet_planning_controller.dart` |
| UI | `vango_app/lib/features/fleet/screens/fleet_planning_screen.dart`; feature `widgets/van_planning_form.dart`, `route_planning_form.dart`, `route_schedule_form.dart`, `fleet_school_selector.dart`, `route_point_picker.dart` |
| Integration/docs | Existing `vango_app/lib/features/fleet/screens/fleet_owner_dashboard_screen.dart`, `vango_app/lib/core/routes/app_routes.dart`, `README.md`, `vango_app/README.md`, `be-tech-plan.md` |

New unit tests live in `vango_app/test/unit/features/fleet/`, named after the production model/service/controller. Widget tests live in `vango_app/test/widget/features/fleet/`, named after each screen/form/selector. Reuse delivered test support instead of building another authentication fake.

## Preparation: establish the actual integration baseline

- [ ] Read CONTRIBUTING.md, this spec, the #16 spec/plan, and the delivered #12/#13 contracts. Inspect `git status --short`, refs, and attached worktrees. Record reviewed prerequisite commit IDs before integrating; do not select a branch only because its name looks current.
- [ ] Establish a reviewed base containing the actual #8 deliveries. Include #16's projection if delivered; if #16 remains parallel, record that combined #16/#17 projection verification is still required before release. Resolve projection changes additively. Do not claim the old `0bf4710` checkout already includes these prerequisites.
- [ ] Capture `get_fleet_planning` owner/driver JSON fixtures from that base, with all existing keys and authorization behavior. This is the compatibility oracle for Task 4, not a hand-built list of remembered fields.
- [ ] Confirm the catalog prerequisite provides authoritative municipality lookup and the institution publication/coordinate-validation contract. Bind coverage validation to those actual schema identifiers in the task notes before Task 1; do not invent a competing catalog table. Backend/UI work can use controlled fixtures, but production acceptance remains blocked until the real prerequisite is delivered.
- [ ] Use a dedicated disposable local Supabase stack. Existing worktrees share project ID and ports; verify ownership before starting/resetting anything. If occupied, use an external temporary project configuration with unique ports and copied migrations/test fixtures. Never reset a shared or remote database. Record local DB/API URLs outside version control without tokens in output.

For selected pgTAP files, use the existing `supabase/tests/run_database_tests.py` include-expansion behavior. Pass expanded temporary files to `supabase test db --local --workdir "$VANGO_TASK17_DB_DIR" <expanded-test-path>`; keep temporary files outside the repository. Full-suite invocation must target the same verified local stack. Test failures due to an unavailable stack are blockers, not RED evidence.

### Task 1: Enforce coverage invariants at every write boundary

**Files:** Coverage migration and test/helper files from the map. Read existing authorization migration `20260906201646_create_cycle_2_authorization.sql` and coverage audit migration `20260906201925_create_marketplace_functions.sql` in full.

**Interfaces:** Preserve relation schemas and read/write contracts. Add `private.lock_service_coverage() returns trigger` as a BEFORE STATEMENT lock trigger and `private.enforce_fleet_service_coverage() returns trigger` as the row invariant trigger, shared by city/school mutation triggers, using the catalog prerequisite's verified lookup. Keep existing `private.audit_service_coverage()` auditing.

- [ ] Write the first pgTAP case: confirmed owner A directly inserting a school whose city is not linked must fail with `invalid_input`, and both relation/audit counts remain unchanged. Add one controlled published school and authoritative city through `_fleet_planning.psql`; never use production catalog data as a fixture.
- [ ] Run `052_fleet_planning_coverage.test.sql`; expect the missing-city assertion to fail against the old permissive boundary.
- [ ] Implement the invariant trigger and confirmed-owner policies: authoritative SP municipality metadata, current actor, active/published institution, validated finite coordinates, same-fleet city link. Acquire `private.lock_planning()` in the BEFORE STATEMENT trigger before row locks, and validate against current committed state after lock acquisition; the concurrency test must prove this under real transaction snapshots. Reject prohibited metadata rather than trusting client labels.
- [ ] Run the focused test; then incrementally add negative/positive cases for anon, unconfirmed owner, driver, inactive member, owner B with known fleet A UUID, forged actor, wrong city name/state, non-SP/unknown city, invalid coordinate pair, unpublished school, and valid owner insertion. Each policy case covers its actual INSERT/UPDATE/DELETE privilege boundary.
- [ ] Add RED cases for city deletion with linked institutions and school unlink with route/active enrollment/reservation references; implement protected removal through the same locked boundary. Test allowed unused removal and rollback of the existing audit trigger failure. Harden legacy route validation against empty/duplicate/unserved/unpublished schools.
- [ ] Verify focused pgTAP plus existing coverage/route tests pass. Document the chosen catalog identifiers and direct-write compatibility. Conditional commit: `feat(planning): enforce fleet coverage invariants`.

### Task 2: Add edit versions without changing route calculation revisions

**Files:** Edit-revisions migration and `053_fleet_planning_edit_revisions.test.sql`.

**Interfaces:** `edit_revision bigint` on `public.vans`, `public.routes`, `public.route_schedules`; `private.advance_planning_edit_revision() returns trigger`; `private.advance_route_school_edit_revision() returns trigger`. Values start at `1`; known business changes strictly increase them. A wrapper never manually increments a revision already handled by triggers.

- [ ] Add/run a RED assertion that a legacy `save_van` change advances its persisted edit version; expect missing-column or explicit missing-contract failure, then implement the column/trigger.
- [ ] Repeat RED/GREEN for route and schedule editable fields/status, including legacy RPCs, route-school insertion/deletion/reordering, and both old/new parents if a relation can change route. Compare `after > before`, not `after = before + 1`.
- [ ] Test that route computation bookkeeping alone does not pretend an owner changed configuration; preserve existing routing-revision behavior. Replaying an accepted command in Task 3 must not change either version.
- [ ] Test unauthorized direct updates cannot set versions, and rollback restores both fields and versions. Use the planning lock order for shared mutation paths; do not introduce entity-lock-before-global-lock inversion.
- [ ] Verify focused tests and existing reservation/resource protection tests. Conditional commit: `feat(planning): version editable fleet configuration`.

### Task 3: Make saves, role enabling, and coverage links atomic and retry-safe

**Files:** Command migration and `054_fleet_planning_commands.test.sql`.

**Interfaces:** Implement the exact six write signatures in spec section 7. New save overloads return UUID; role adapter returns `text[]`; link RPCs return void. `private.fleet_planning_commands` stores `(fleet_id, command_id)` primary key, actor, operation, canonical hash, immutable original result JSON, timestamp. Keep logic local to these commands; no generic dispatch RPC.

- [ ] Write/run a RED test calling the new van overload twice with one command and explicit null ID/revision, asserting the same UUID, one entity, one existing audit sequence, one receipt. Implement the narrow receipt table and van wrapper by delegating the old six-argument function inside one transaction.
- [ ] Repeat RED/GREEN for route and schedule wrappers. Verify syntactic input then authorized receipt replay before mutable validation/CAS; verify new edits compare expected revision under lock. Canonical hash includes version, operation, target, full normalized payload, and expected revision. School order is meaningful; weekday sets are sorted only after rejecting duplicates.
- [ ] Add RED/GREEN cases: changed actor/operation/payload/expected version -> `idempotency_conflict`; stale fresh edit -> `revision_conflict`; A -> B -> replay A returns A UUID and leaves B intact; legacy intervening edit invalidates a new stale command. Invalid create/edit null combinations fail without effects.
- [ ] Add/run role-adapter RED cases preserving manual sources and derived-role provenance. Implement self-only membership resolution, current confirmed-owner validation, lock, role-source merge, and existing `set_fleet_member_roles` delegation. Already-enabled is a no-op receipt. Removal followed by delayed replay must not re-enable the driver.
- [ ] Add/run link-RPC RED cases. Derive city metadata and actor server-side, retain Task 1 invariants and audit triggers, create receipts atomically. Repeated links with distinct commands succeed without duplicate link/audit; identical replay returns the original success marker.
- [ ] Inject audit failure and receipt-insert failure separately with transaction-local test triggers. Assert full snapshots of domain rows, membership sources, versions, audit rows, and receipts are unchanged. Never leave fault injection in production migrations.
- [ ] Assert exact `pg_proc` argument types/names, no defaults on new overloads, `SECURITY DEFINER`, safe search path, and privileges by full signature. Revoke private function execution/table access from PUBLIC/anon/authenticated; grant public RPC execution only to authenticated. Preserve old signature grants explicitly. Exercise actual unauthorized calls as well as catalog privilege checks.
- [ ] Verify focused tests and registration/#16/marketplace regressions. Conditional commit: `feat(planning): persist atomic planning command receipts`.

### Task 4: Preserve the integrated projection and prove the HTTP/concurrency contracts

**Files:** Projection migration, `055_fleet_planning_projection.test.sql`, concurrency and HTTP scripts from the map.

**Interfaces:** `public.get_fleet_planning(p_fleet_id uuid) returns jsonb` retains the integrated contract and adds owner `edit_revision`, endpoints, ordered schools, coverage, drivers, and owner operator fields from the spec. Test scripts use existing installed PostgreSQL client support and Python stdlib HTTP; no new dependency or paid API.

- [ ] Write/run RED tests comparing the integrated fixtures after stripping only #17 additions: remaining structures must equal baseline values/keys/types. Cover owner, assigned driver, unassigned driver, foreign owner, anon, empty fleet, and #16 `enrollment_revisions` where integrated. Implement additions in the latest function body, not by copying the #11 version.
- [ ] Assert owner fields are complete and ordered; driver responses gain no owner-only properties. Preserve route labels and routing revisions as well as new endpoint objects. Profile display names are nullable, user IDs are stable, no email/contact leakage. Test malformed/unpublished coverage cannot become a selectable school.
- [ ] Create the real two-session script using barriers and `pg_stat_activity` lock-wait evidence from existing concurrency harnesses, not sleep-only timing. Run `python3 supabase/tests/concurrency/fleet_planning.py` against the verified disposable local DB. Cases: same command -> one result/audit/receipt; different commands at the same version -> one winner and one revision conflict; school link versus city removal; route creation versus school unlink -> one valid serial outcome, never a dangling relation. Include a role-revocation race and verify ordering/access after lock acquisition. Cleanup only this run's fixture IDs in `finally`.
- [ ] Create `python3 supabase/tests/http/fleet_planning.py` using local test sessions without logging tokens. Refresh PostgREST schema cache and wait for readiness. Send exact old and new named JSON sets for all three save functions, explicit create nulls, and valid edits. Assert successful HTTP status, scalar UUID, entity values, audit/receipt counts, and no ambiguous-function error.
- [ ] Add HTTP cases for omitted command/revision, extra keys, wrong types, invalid null pairs, anon, foreign owner, role adapter, link adapters, and projection. Assert rejection leaves state unchanged; partial new-key sets never dispatch to old overloads. Require live PostgREST success, not a mocked HTTP client or SQL-only function test.
- [ ] Rerun projection/command pgTAP and both scripts; retain sanitized evidence. Conditional commit: `feat(planning): extend integrated planning projection`.

### Task 5: Parse and send typed planning contracts

**Files:** Model, command, service and error-mapper files from the map; matching `fleet_planning_test.dart`, `fleet_planning_service_test.dart`, `fleet_planning_error_mapper_test.dart` under unit/features/fleet.

**Interfaces:** `FleetPlanning.fromJson(Map<String, dynamic> json)`; typed `PlanningVan`, `PlanningRoute`, `PlanningSchedule`, `PlanningPoint`, `PlanningCity`, `PlanningSchool`, `PlanningDriver`, `OwnerOperator`. `FleetPlanningService.load(String fleetId) -> Future<FleetPlanning>`; `saveVan(VanPlanningCommand)`, `saveRoute(RoutePlanningCommand)`, `saveSchedule(SchedulePlanningCommand) -> Future<String>`; `enableOwnerDriving(String fleetId, String commandId) -> Future<List<String>>`; `linkCity(String fleetId, String cityIbgeCode, String commandId)` and `linkSchool(String fleetId, String schoolId, String commandId) -> Future<void>`.

Command objects are immutable, with exact API fields, `commandId`, nullable entity ID/expectedRevision, and a `toRpcParams()` map preserving explicit nulls. Reuse existing matching catalog/date types from the integrated source; do not duplicate `SchoolOption`. `PlanningResponseFormatException` denotes malformed known response data, distinct from domain rejections or transport uncertainty.

- [ ] Write/run model RED tests using the integrated owner fixture: unknown top-level and nested fields are ignored; missing required field throws; explicitly nullable pairing/name is accepted only where specified. Run `flutter test test/unit/features/fleet/fleet_planning_test.dart` from `vango_app`.
- [ ] Implement strict parsing, then incrementally test UUIDs, positive integer edit revisions, enums, NaN/infinite/out-of-range coordinates, numeric strings/fractional counts, invalid dates, ordered arrays, and valid PostgreSQL `HH:mm:ss` time values. Reject malformed known fields without fallback; retain known legacy projection collections even when not rendered.
- [ ] Write/run service RED tests asserting exact named RPC parameters for every method, creation nulls, stable command IDs, and no request without the correct authenticated context. Implement typed mapping using existing Supabase injection patterns. Catalog search reuses the existing service contract and city/type filters; no direct widget writes.
- [ ] Write/run error-map RED tests for every spec code, especially `revision_conflict`, `idempotency_conflict`, access loss, invalid format, definitive backend rollback, and unknown transport outcome. Map by structured codes, never message substrings; do not expose SQL/provider text.
- [ ] Run the three focused unit files and format touched files. Conditional commit: `feat(planning): add typed planning service contracts`.

### Task 6: Preserve command identity and context through asynchronous state changes

**Files:** Controller file and `vango_app/test/unit/features/fleet/fleet_planning_controller_test.dart`.

**Interfaces:** `FleetPlanningController` extends `ChangeNotifier`, constructed with the typed service and current user/fleet context. Expose `load()`, `saveVan(VanPlanningCommand)`, `saveRoute(RoutePlanningCommand)`, `saveSchedule(SchedulePlanningCommand)`, `enableOwnerDriving()`, `linkCity(String)`, `linkSchool(String)`, `retryPending()`, and `clearContext()` returning `Future<void>` for async operations and void for clear. State includes typed projection, load/error status, immutable pending submission, and write outcome `idle | submitting | uncertain | rejected | committed`. Context invalidation discards pending state; read failure after commit is separate from write outcome.

- [ ] Write/run RED tests with controlled completers: account/fleet change before load/search/write/reload completion ignores the old result and clears sensitive data. Implement context plus generation guards at every completion boundary, including errors/finally blocks.
- [ ] Write/run RED tests: double tap sends one command; timeout retains the exact ID/payload/revision; retry reuses them; committed write plus failed reload sends only another read; validation rejection preserves draft; revision conflict never automatically substitutes the new revision. Implement these state transitions using the delivered #12/#13 pattern without importing registration-specific errors.
- [ ] Test role success refreshes access context and projection before operator selection; partial refresh failure shows confirmed write plus read error. Test logout blocks a pending retry and app restart loads persisted state without recreating forgotten submissions.
- [ ] Run `flutter test test/unit/features/fleet/fleet_planning_controller_test.dart` and all Task 5 tests. Conditional commit: `feat(planning): guard planning submission state`.

### Task 7: Build independent forms and integrate the owner flow

**Files:** UI files and matching widget tests from the map, plus the existing dashboard/routes. Reuse delivered authentication and map configuration without modifying driver/marketplace flows.

**Interfaces:** `FleetPlanningScreen` receives the existing `OwnerFleetRouteArguments` and authenticated services. Forms receive typed initial values/options and emit validated command input to the controller. `RoutePointPicker` receives optional `PlanningPoint` and returns a confirmed point or null on cancel; no automatic saved map center. `FleetSchoolSelector` consumes served-city-filtered published catalog results and emits an ordered unique school list.

- [ ] Write/run screen RED tests for authorized navigation, invalid/missing arguments, loading, true empty fleet, read error/retry, partial setup, and unchanged student registration entry. Implement persisted section summaries and dashboard navigation.
- [ ] Write/run van form RED tests for create/edit, capacity boundaries `1/100`, required fields, plate conflict, stale revision feedback, and retained draft. Implement native controls and exact backend command mapping.
- [ ] Write/run route form RED tests for explicit driver selection and self-driver action, direction/shift, ordered unique schools, accessible move-up/down, valid endpoints, proximity boundaries, preserved paired route, and resource-in-use rejection. Implement only the approved fields.
- [ ] Write/run point-picker RED tests: opening/moving map does not confirm; cancel returns null; finite selected point plus nonblank label confirms; catalog endpoint selection uses validated coordinates; tile failure never saves a default point. Reuse installed map stack and provide accessible explicit confirmation with coordinate/label feedback.
- [ ] Write/run schedule form RED tests for ISO weekdays, same-day versus overnight, timezone preservation, date validity, and `0/1440` confirmation bounds. Implement native date/time controls with civil-date values; do not infer fixture validity or create a return route automatically.
- [ ] Test pt-BR error text, large text scaling, small viewport scrolling, keyboard focus, visible field labels, non-color status, and invalidation during submission. Run `flutter test test/widget/features/fleet` plus all new unit tests. Conditional commit: `feat(planning): configure fleet routes and schedules`.

### Task 8: Verify persisted flow and document the delivered contracts

**Files:** `vango_app/integration_test/fleet_planning_test.dart`, existing READMEs and `be-tech-plan.md`. No production code additions unless a demonstrated failure requires a focused RED/GREEN fix.

- [ ] Write/run an integration test against the isolated backend: owner links city/school, saves van, explicitly enables self-driving or chooses another active driver, saves route then schedule, closes/reopens the flow, and reads identical IDs/values. Assert no allocation or trip-generation command was issued. Keep provider access faked or local in automated tests.
- [ ] Run all database tests on the verified isolated stack, migration-from-scratch validation, `supabase db lint --local --workdir "$VANGO_TASK17_DB_DIR"`, HTTP/concurrency scripts, and relevant existing concurrency regressions. Do not weaken local-only safety guards to force harness compatibility.
- [ ] From `vango_app`, run `flutter test --coverage`, `flutter analyze`, and `dart format --output=none --set-exit-if-changed .`. Require zero analyzer issues and at least 80% business/domain coverage. Record existing unrelated failures separately without claiming a clean gate. Run Deno lint/check/tests only if Edge Function code actually changed.
- [ ] Update docs with exact overload parameter sets, required creation nulls, revision conflicts, receipt/replay behavior, grant signatures, catalog prerequisites, and test commands. Update `.env.example` only if an approved runtime key was introduced; none is planned.
- [ ] Invoke software-quality-gate before claiming implementation completion. Check git status before/after; scanner tooling stays outside the repository, installs no project dependency, creates no tests, changes no lock/config files, and leaves no generated artifacts. Remove only generated files owned by this run, preserving pre-existing files.
- [ ] Run `git diff --check`, review scope and complete spec acceptance evidence. Conditional commit: `docs(planning): document verified owner configuration flow`. A catalog delivery gap or missing combined #16 projection check remains explicit; do not call the entire PRD delivered.

## Self-review and execution handoff

Spec coverage: coverage rules -> Task 1; edit protection -> Task 2/3; atomic domain/audit/receipt and owner-driver adapter -> Task 3; integrated shape, grants and live HTTP/concurrency -> Task 3/4; strict-known/additive-tolerant parsing -> Task 5; async/retry semantics -> Task 6; approved independent forms/map -> Task 7; persistence and release evidence -> Task 8. All five Review Focus items have owning tests.

The integration commit IDs and catalog schema binding are explicit preparation gates because they are not delivered facts in this checkout. No extra product decision is needed to write the plan, and fixture success cannot waive these release requirements.

Recommended execution: native, in this session, in task order; the database lock/revision/receipt contracts are tightly coupled. After the user's plan review and execution-method choice, use executing-plans and perform the required independent final review. Do not begin implementation or commit/push on the strength of planning approval alone.

## Execution result — 2026-09-26

The checklist above is the original test-first plan; this section records actual
delivery evidence. Implementation was native in the #17 worktree, based on merge
`a3d57d2` (delivered #12/#13 plus #16). One final independent reviewer and one
regression-fix pass were used. Commit/push are authorized by the user.

| Task | Delivered evidence |
| --- | --- |
| 1 — Coverage | Database coverage constraints, publication lookup, all institution selectors, both city/school race orderings |
| 2 — Edit revisions | Legacy edits, route-school ordering, schedule fields, computation-only stability, client revision-write denial |
| 3 — Commands | Exact signatures/grants, normalized replay, stale edits, immutable receipts, audit/receipt fault rollback, owner-driver replay after removal |
| 4 — Projection/integration | Frozen integrated projection comparison, exact unchanged driver shape, missing profile name, actual PostgREST overload dispatch, eight planning races |
| 5 — Typed contracts | Strict known fields, additive-key tolerance, immutable payloads, exact service arguments, malformed-response rejection |
| 6 — Controller | Duplicate submit, uncertain retry, read failure after commit, superseded catalog results, session and fleet changes |
| 7 — Forms | Independent forms, required explicit map point, institution ordering, native schedule controls, small screen/large text, stale draft and picker context clearing |
| 8 — Delivery | Clean migration/seed reset, 1,178 SQL assertions, 202 Flutter tests, live native persistence, web build, zero analyzer issues, 81.40% business coverage |

Additional regression suites: eight #17 races, seven #16 races and the original
resource/allocation races all passed, including cleanup. The normal Flutter suite
skips the opt-in live test; that test separately passed with a real local session.
No allocation/trip generation is added by this flow.

Decisions and limits:
- The catalog prerequisite uses authoritative municipality metadata and private
  fingerprinted publication evidence. Synthetic fixtures never establish statewide
  readiness; no real INEP/e-MEC dataset was imported.
- Native integration uses the existing `flutter_test` runner under
  `test/integration/`, avoiding a new plugin. HTTP proves the full persistence
  sequence, native client tests prove parsing/reopen/replay, and widgets prove UI
  interactions; physical-device automation is not claimed.
- Registration's secure UUID generator was extracted and reused. No runtime
  dependency or environment key was introduced.
- Exact legacy parameter sets remain supported; partial new argument sets fail
  dispatch. Omission of both new keys cannot communicate revision-aware intent.
- A final commit per issue replaces the plan's conditional step commits, following
  the user's commit-after-finishing instruction.
- Observed RED/GREEN evidence includes missing revisions/receipts, coverage rules,
  unknown nested fields, canonical replay, fleet rebind, registration/unlink and
  point-picker invalidation. Some initial contract tests were scaffolding checks;
  full historical strict-TDD provenance is not claimed.
- Quality gate: WARNING for 21 reproducibly pre-existing formatting differences,
  16 DB lint warnings in six untouched legacy functions, and validation complexity.
  All changed Dart files format cleanly, all new SQL functions lint without warnings,
  and the quality scan left repository state unchanged.
- Independent review P1 (registration/unlink race) and P2 (point-picker session
  privacy) were fixed with observed regression failures and passing final checks.
  Separate catalog acquisition, production deployment and paid-provider/device
  acceptance remain outside the claims of this branch delivery.
