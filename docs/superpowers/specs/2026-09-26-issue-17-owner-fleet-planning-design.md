# Issue 17: Owner Fleet Planning Design

**Status:** Consolidated after user approval and requested safeguards on 2026-09-26. Native implementation validated for branch delivery; real statewide catalog acquisition and production deployment remain separate.
**Date:** 2026-09-26
**Issue:** [#17](https://github.com/VictorAlexandreLeitePolonio/vango-be/issues/17), part of [PRD #15](https://github.com/VictorAlexandreLeitePolonio/vango-be/issues/15).
**Branch:** `codex/task-17-owner-fleet-planning`, integrated #12/#13 commit `130c8fa` and #16 commit `9d7013f` through merge `a3d57d2`.
**Catalog prerequisite:** [Sao Paulo institution catalog design](2026-09-26-sao-paulo-institution-catalog-design.md).

## 1. Product outcome and agreed constraints

An authenticated fleet owner configures real service cities/schools, vans, a qualified operator, routes, and recurring schedules. Reloading the app retrieves that configuration from Supabase. A successful save means the backend accepted it; neither a failed request nor an empty fleet produces demonstration data.

The user confirmed that the catalog must cover public and private schools and higher-education campuses across the entire state of Sao Paulo, including the interior. Search is filtered by cities served by the fleet. Institutions must have validated coordinates before they become available; administrative location correction is allowed before publication. The fleet owner selects and links catalog institutions rather than creating arbitrary global institutions.

The approved #16 design supports explicit day/direction allocations and complete effective-dated replacement, but selecting students for schedules belongs to #18. #17 creates the resources that #18 needs. Daily materialization, trip actions, GPS, marketplace expansion, school-transfer scheduling, catalog administration UI, and a general fleet-membership editor are outside #17.

## 2. Approach and alternatives

**Recommended:** A focused planning screen plus small edit forms, using the existing Flutter Material components, theme tokens, Supabase services, and authenticated fleet context. Persist each complete entity separately and reload the projection after a confirmed write. This permits an owner to resume setup without retaining a large local wizard draft.

**Alternative:** One multi-step wizard that holds van, driver, route, and schedule drafts until the end. It would add cross-step draft ownership and partial-save recovery while the backend already exposes independent entity commands; it is not recommended for this delivery.

**Alternative:** A broad fleet administration dashboard with catalog curation, membership editing, and route optimization. Those workflows exceed the operational setup needed by this issue and remain out of scope.

This is an architectural change: there is no existing owner planning flow to extend directly. The user approved independent forms, explicit map point selection, and the owner-driver adapter, with the backend safeguards specified below.

## 3. Verified checkout findings and integration baseline

- `FleetOwnerDashboardScreen` already receives `fleetId`, `userId`, and `AuthService`, revalidates access, clears data on session changes, and rejects late responses. Reuse this behavior rather than trusting route arguments as authorization.
- `AccessContext` contains fleet IDs and effective roles, but not membership IDs.
- `FleetService.getFleetDrivers` currently reads memberships/profile relationships, labels all returned records active, and has no active-membership filter. Do not treat it as an authoritative planning-driver list without correcting that contract.
- `get_fleet_planning` contains vans, routes, schedules, reservations, and route revisions. Owner route records omit origin/destination coordinates and ordered schools. The projection also lacks service coverage and owner/operator context.
- `save_van`, `save_route`, and `save_route_schedule` exist and return UUIDs. Their existing signatures have no command ID. A disabled button alone does not protect retries after a response is lost.
- `set_fleet_member_roles` replaces the manual role set. Sending only `['owner','driver']` could remove another manual role; sending every effective role could convert derived grants to permanent manual grants. Role preservation belongs in a locked backend operation.
- `fleet_service_cities` and `fleet_service_schools` have owner-scoped RLS and audited insert/delete behavior. Catalog reads use `search_schools`.
- In the inspected #11 checkout, the literal demo plate is in driver/student paths, not in the owner dashboard. Remove any static owner planning presentation encountered after integration, but do not broaden #17 into a cleanup of the driver/marketplace paths assigned to later issues.
- Newer local branch `codex/task-13-reliability` contains #12 registration UI and the structured uncertain-write pattern in `FleetStudentSubmissionState`. #17 must integrate with the delivered #12/#13 baseline before implementation instead of replacing their dashboard changes. No branches were merged during this design work.

The first implementation preparation step is to establish a reviewed integration base containing the actual delivered #8 work. The #17 branch's original base is a recorded starting point, not evidence that all prerequisites are merged or deployed.

## 4. Owner flow

Add a `Planejamento` entry to the existing owner dashboard. It opens a fleet-scoped screen using `OwnerFleetRouteArguments`; missing/invalid arguments render the existing access-unavailable state. Keep existing student registration and dashboard tabs intact.

The screen contains four sections with persisted summaries and explicit empty states:

1. **Cidades e instituições:** Add a Sao Paulo city from the catalog's authoritative municipal list, search by city/name/type, and explicitly link the selected institution to the fleet. Show institution name, campus/address, municipality, and type so identically named branches are distinguishable. Select multiple served cities; query one city at a time using the existing search contract.
2. **Vans:** Show real model, plate, public name, capacity, and status. `Adicionar van` and `Editar van` use the existing backend constraints: required text fields, supported Brazilian plate formats, capacity `1..100`, duplicate-plate and existing-reservation protection. Inactive vans remain identifiable but cannot be selected for a new route.
3. **Rotas:** Select direction, shift, van, operator, ordered institutions, origin, destination, and proximity minutes. A route is one direction; creating a return route is explicit, never an implicit second write.
4. **Horários:** Configure a schedule under a selected route. Show its weekdays, local start/end, overnight flag, timezone, validity, and confirmation cutoff. A saved route without schedules is a real incomplete-setup state, not an active daily trip.

Forms save one complete entity. Navigating back after a save leaves that entity persisted even if later setup steps are unfinished. No all-or-nothing multi-entity wizard or rollback is implied.

## 5. Owner as driver and operator selection

Offer `Eu também dirijo nesta frota` only as an explicit action. A pure owner is not silently assigned as the route's driver. Already active drivers can be selected, including another fleet driver. No driver-invitation workflow is added here.

Approved narrow backend adapter: `enable_owner_driving(p_fleet_id uuid, p_command_id uuid) returns text[]`. Validate confirmed email and current active owner membership, acquire the planning lock, resolve the caller's membership server-side, read its existing manual role sources, add the driver role, and delegate to the existing `set_fleet_member_roles` behavior. Preserve the owner and all other manual grants without promoting derived guardian/student grants. No target user ID or arbitrary role list comes from Flutter. Replay is access-checked and does not re-grant a role that was subsequently removed.

After success, refresh both authenticated access context and planning. Select the owner as operator only after the persisted projection confirms driver readiness. On error, retain the previous role and show the backend failure; do not update the switch optimistically. Removing the driver role belongs to a separate management workflow.

## 6. Route and schedule fields

### Route

Use the exact existing `save_route` JSON names:

- `name`: nonblank display name;
- `direction`: `going` or `return`, shown as `Ida` / `Volta`;
- `shift`: `morning`, `afternoon`, `evening`, or `full_time`, with pt-BR labels;
- `van_id` and `driver_user_id`: active resources from this fleet's persisted projection;
- `schools`: nonempty ordered objects `{school_id, position}`, unique institution IDs and consecutive positions starting at `1`;
- `origin` and `destination`: `{latitude, longitude, label}`, with finite coordinates and nonblank labels;
- `proximity_minutes`: integer `1..60`, default `10`, clearly explained as the existing proximity threshold;
- `paired_route_id`: preserved on edits if already present; optional opposite-direction pairing is not required to create an MVP route.

Approved location interaction: use validated catalog coordinates when selecting a school endpoint, and a map pin with an owner-entered label for other endpoints. Reuse the installed `flutter_map`/`latlong2` stack and map configuration. Do not use a fixed Sao Paulo city center as an actual saved point or derive official institution identity from an address search. The route point picker does not edit the institution's global coordinates. Saving requires an explicit point confirmation; merely opening or moving the map is not confirmation. Provider-backed address autocomplete is outside this delivery.

Provide accessible move-up/down actions for institution order, not drag-only controls. Display the selected endpoints and ordered schools before saving. Existing routes with reservations may reject resource changes with `resource_in_use`; preserve the form and explain the restriction instead of silently reassigning reservations.

### Schedule

Use the existing `save_route_schedule` JSON names and values:

- `weekdays`: unique ISO weekday integers `1..7`, at least one;
- `starts_at`, `ends_at`: local `HH:mm` strings;
- `ends_next_day`: explicit boolean, labeled `Termina no dia seguinte`;
- `timezone`: default `America/Sao_Paulo` for this SP workflow; display it and preserve existing non-default values on edits;
- `valid_from`, `valid_until`: explicit civil dates, never UTC timestamp conversions;
- `confirmation_minutes`: integer `0..1440`; show the selected cutoff before save.

For same-day schedules, end must follow start. Overnight schedules use the explicit flag. Let the backend enforce resource overlaps, validity, reservation protection, and timezone support. Client validation improves feedback but does not authorize or override domain rules. Do not infer a 90-day validity or confirmation cutoff from test fixtures; the owner enters these values.

## 7. Backend contracts and transaction guarantees

### Planning projection

Start from the latest function definition in the reviewed integration base, never from the original #11 migration. Before changing it, record its complete JSON shape and role-specific fixtures, including #16's `enrollment_revisions` if integrated. Preserve every existing key, value type, nullability, ordering, filter, and permission boundary; the additions below must not reconstruct or truncate the old response:

| Owner-only addition | Fields |
| --- | --- |
| Route `origin` and `destination` | `latitude`, `longitude`, `label` |
| Route `schools` | Ordered `school_id`, `position`; details reference the coverage list |
| `service_cities` | `city_ibge_code`, `city_name`, `state_code` |
| `service_schools` | `school_id`, `institution_type`, name/address/city identifiers, validated latitude/longitude |
| `drivers` | Active `user_id` and display name; no email/contact payload |
| `owner_operator` | Caller membership ID and effective `is_driver` boolean; no editable arbitrary roles |

Keep driver-only views restricted to their current assigned-route scope. Do not expose the new owner-only arrays or route details to them. Source joins occur inside the authorized projection; do not work around hidden profile rows by broadening profile RLS. Missing display names use `Motorista`, while the valid user ID remains the selection key.

Coordinate validity is enforced in catalog publication and again for selected schools/endpoints in route creation, without fabricating a replacement coordinate. The final catalog contract defines its validation provenance. Reject empty/duplicate school lists at the command boundary rather than relying only on widgets.

### Edit revisions

Add `edit_revision bigint NOT NULL DEFAULT 1 CHECK (edit_revision > 0)` to vans, routes, and route schedules. This is an opaque monotonic configuration version, separate from route calculation `routing_revision` and enrollment revisions. Expose it on each owner entity. Database triggers advance it on changes to persisted editable fields/status through every entry point, including legacy RPCs; ordered `route_schools` changes advance the parent route version. Clients cannot set it. A logical command may advance the route version more than once; clients compare equality, never assume `previous + 1`.

Each new save overload requires `p_expected_revision bigint` as well as `p_command_id uuid`, both without defaults. For creation, entity ID and expected revision must both be null; for editing, both must be present and revision positive. Under the existing planning lock, compare with the current entity version before mutation. A mismatch produces `revision_conflict` (409), with no mutation, audit, or receipt. The UI preserves the draft and offers reload/review; it never retries automatically with a fresh revision. Existing signatures retain their parameter/return contracts and advance revisions on mutation, but cannot offer stale-edit rejection because they receive no expected version. The #17 UI always uses the new signatures.

### Exact public signatures and grants

All signatures below use `SECURITY DEFINER SET search_path = ''`, validate current confirmed-owner access, and have explicit `REVOKE EXECUTE ... FROM PUBLIC, anon; GRANT EXECUTE ... TO authenticated;` statements individually. Creation nulls are explicit JSON nulls, not omitted keys.

| Function | Ordered parameters | Result |
| --- | --- | --- |
| `save_van` new overload | `p_fleet_id uuid, p_van_id uuid, p_plate text, p_model text, p_public_name text, p_capacity integer, p_command_id uuid, p_expected_revision bigint` | `uuid` |
| `save_route` new overload | `p_fleet_id uuid, p_route_id uuid, p_config jsonb, p_command_id uuid, p_expected_revision bigint` | `uuid` |
| `save_route_schedule` new overload | `p_route_id uuid, p_schedule_id uuid, p_schedule jsonb, p_command_id uuid, p_expected_revision bigint` | `uuid` |
| `enable_owner_driving` | `p_fleet_id uuid, p_command_id uuid` | `text[]` |
| `link_fleet_service_city` | `p_fleet_id uuid, p_city_ibge_code text, p_command_id uuid` | `void` |
| `link_fleet_service_school` | `p_fleet_id uuid, p_school_id uuid, p_command_id uuid` | `void` |
| `get_fleet_planning` unchanged | `p_fleet_id uuid` | `jsonb` |

Also explicitly retain the grants/revokes for legacy `save_van(uuid,uuid,text,text,text,integer)`, `save_route(uuid,uuid,jsonb)`, and `save_route_schedule(uuid,uuid,jsonb)`. New signatures are respectively `(uuid,uuid,text,text,text,integer,uuid,bigint)`, `(uuid,uuid,jsonb,uuid,bigint)`, and `(uuid,uuid,jsonb,uuid,bigint)`. Do not grant by bare function name or silently revoke compatible callers. Every new private function is revoked from `PUBLIC, anon, authenticated` by its full argument types and granted only to the execution roles that need it. Private receipt tables have RLS and no client schema/table privileges; test reads and writes independently. Audit mutation permissions remain restricted.

### Atomic commands and replay

Use `private.fleet_planning_commands`, keyed by `(fleet_id, command_id)`, with nonnull actor, operation, canonical payload hash, original result JSON, and timestamp. Results contain the original UUID/roles or a void success marker, plus the post-write entity revision when relevant. Receipts are immutable and do not expire or cascade away with mutable configuration. Do not share receipts with #10 or #16.

Each command executes in one database transaction:

1. Authenticate, derive the fleet for schedule operations, acquire `private.lock_planning`, then revalidate current owner membership and confirmed email before inspecting any receipt. Follow the existing lock order before entity rows; coverage and configuration paths use the same lock.
2. Validate syntactic input and build a versioned canonical hash including operation, target, all business inputs, explicit creation nulls, and expected revision. Normalize JSON object key order and existing plate normalization; preserve school order, sort set-valued weekdays, and reject duplicates/unknown command keys rather than silently dropping them. Compare actor separately.
3. If the receipt exists, return its original result only for identical actor/operation/hash. Otherwise raise `idempotency_conflict` (409). Replay precedes mutable resource validation and revision comparison, but never precedes current access checks.
4. For a new command, enforce revision and domain invariants, call existing domain behavior, retain its existing sanitized audit event(s), and insert the immutable receipt before returning. Coverage uses existing audit triggers; role enabling uses existing role auditing. Do not add a duplicate wrapper audit. Audit failure or receipt insertion failure rolls back every domain effect and revision increment. Do not catch a failed sub-operation and return success.

Concurrent identical commands serialize and yield one mutation, one logical audit sequence, one receipt, and the same result. Concurrent distinct edits with the same expected revision yield one winner and one `revision_conflict`. A -> B -> delayed A returns A's original receipt without reverting B, including owner-driver removal after A. A fresh command that links already-linked coverage is a successful no-op with its own receipt and no second coverage audit. An already-enabled owner likewise produces no duplicate role mutation/audit. An uncertain response retains the same command ID and immutable payload. A confirmed write with failed reload retries only the read.

### Coverage invariants belong in the backend

The app uses the narrow link RPCs above; no client-supplied city name/state or `created_by` is trusted. Resolve municipality code/name/state from the authoritative SP catalog prerequisite and actor from `auth.uid()`. Reject unknown or non-SP municipalities. A linked school must be an active, published institution with validated finite coordinates, and its authoritative city must already belong to the same fleet. Do not silently link an extra city when linking its school. Reject inactive/unpublished institutions, invalid coordinates, foreign city coverage, and forged actor/municipality metadata through direct relation writes too.

Retain existing relation read/write contracts with tightened confirmed-owner RLS and invariant triggers so legacy clients cannot bypass the rules. Insert/update/delete checks and link RPCs serialize with planning writes. A `BEFORE STATEMENT` trigger acquires the existing global planning advisory lock before coverage row locks; row triggers then validate invariants. Do not acquire the global lock for the first time in an after-row trigger. Database checks after waiting must read current committed state; prove the link/delete outcome using two real sessions. Prevent deletion of a served city while linked institutions remain; prevent unlinking an institution referenced by a route or active enrollment/reservation. No cascade removal or coverage-removal UI is introduced. Route saves, including legacy signatures, recheck ordered unique served institutions and valid coordinates at the backend. Administrative catalog status/coordinate changes must obey the publication contract and cannot fabricate replacement locations.

The separate catalog prerequisite must expose authoritative municipality lookup and published coordinate provenance before production coverage is accepted. Tests may use controlled fixtures; they do not prove statewide delivery. Its acquisition/geocoder choice remains outside #17.

### PostgREST compatibility evidence

Test real HTTP requests against the local PostgREST instance after migrations and schema-cache refresh. Call each legacy save with its exact old named parameters and each new overload with the full new named set, including explicit null ID/revision for create. Assert the expected scalar UUID and persisted entity, authenticated authorization behavior, and absence of `PGRST203`/ambiguous resolution. Missing command/revision keys, extra keys, wrong types, and invalid null combinations must fail without effects, never dispatch to a legacy writer. Check anonymous and foreign-owner requests, role and coverage adapters, and unchanged projection routing. SQL function existence tests alone do not satisfy this acceptance criterion.

## 8. Flutter boundaries and state

Keep planning under `vango_app/lib/features/fleet/`:

| Proposed file | Responsibility |
| --- | --- |
| `models/fleet_planning.dart` | Immutable typed projection models and strict boundary parsing. |
| `models/fleet_planning_commands.dart` | Validated van/route/schedule input records and immutable submitted payloads. |
| `services/fleet_planning_service.dart` | Typed Supabase planning RPCs and service-coverage writes; no UI text or widget dependencies. |
| `services/fleet_planning_error_mapper.dart` | Structured domain-code classification and safe pt-BR feedback. |
| `controllers/fleet_planning_controller.dart` | Load/write/reload state, request generations, immutable pending command, and session/fleet invalidation. Use built-in ChangeNotifier; no new state-management dependency. |
| `screens/fleet_planning_screen.dart` | Persisted section summaries and loading/empty/error states. |
| `widgets/van_planning_form.dart`, `route_planning_form.dart`, `route_schedule_form.dart` | Focused forms with native text/date/time controls. |
| `widgets/fleet_school_selector.dart`, `route_point_picker.dart` | Catalog selection/order and explicit point selection. |
| Existing `fleet_owner_dashboard_screen.dart` and `core/routes/app_routes.dart` | Small navigation integration preserving #12/#13 work. |

Prefer existing types where semantics match; do not copy `SchoolOption` if it needs only an additive campus/location field. Do not repurpose registration-specific models or error strings as planning models. Exact Dart interfaces and incremental tests are defined in the implementation plan.

Projection parsing ignores unknown object keys, including nested additions, but validates all known fields: required versus explicitly nullable values, UUIDs, positive integer revisions, enum values, finite coordinate ranges, array element shapes/order, ISO civil dates, and local times. Postgres time strings with seconds must be accepted when valid; do not assume the read format is the form's `HH:mm` input format. Missing required fields, numeric strings, fractional integers, unknown enum values, impossible dates, and nonfinite coordinates raise a typed response-format error. Do not coerce malformed data into zero coordinates, empty arrays, or success. Optional display names alone use the documented `Motorista` fallback. Preserve legacy projection data even when the screen does not render it.

Controller ownership is `(userId, fleetId)` with a monotonically increasing request generation. Every load, search, write completion, and reload must verify the same context before changing UI state. Logout, account/fleet change, or loss of access clears the projection, form state, and pending command. Never send a previous fleet's retry under a new session.

Use the #12/#13 uncertain-write behavior as a reference: one immutable command ID/payload per logical submission, no second submit while unresolved, safe retry with the same ID, and no automatic new ID after timeout. Reuse the installed Supabase command-ID generator used in registration rather than adding a UUID dependency. Unsaved form drafts are local. Cross-restart recovery of an unresolved command requires explicit design if requested; the MVP always reloads persisted configuration on restart and must not auto-resubmit a forgotten draft.

## 9. Errors and accessibility

Map `revision_conflict`, `schedule_conflict`, `resource_in_use`, `capacity_exceeded`, `plate_conflict`, `invalid_input`, `email_unverified`, access errors, and `idempotency_conflict` by structured code. Network timeout/unknown failure is not proof of rollback. Preserve user input after a definitive validation rejection and retain the original immutable command while its result is uncertain.

Examples: `Este horário conflita com outra rota.`, `Este recurso já está em uso por uma programação.`, `Já existe uma van com esta placa.`, and `Não foi possível confirmar o envio. Tente verificar novamente.` Do not show raw SQL/provider errors, log full addresses/coordinates, or substitute demo data.

Use visible field labels, announced validation messages, focus management, scalable text, touch targets, scrollable forms, and non-color-only status. Keyboard/date/time controls remain usable on small screens. A map failure does not silently select a default point.

## 10. Required tests and acceptance

| Layer | Evidence |
| --- | --- |
| Database projection | Owner sees complete fields; driver/foreign/anonymous callers do not gain owner details; #16 additions survive integration. |
| Role adapter | Explicit self-enablement persists owner+driver, preserves other manual/derived sources, rejects foreign/inactive callers, and does not re-grant on delayed replay after removal. |
| Write commands | Real two-session races for identical commands and stale competing edits; domain/audit/receipt failure rollback; delayed replay; full-signature grants/revokes and live PostgREST overload resolution. |
| Coverage | Confirmed owner, actor and authoritative city metadata, published school coordinates, required city link, direct-write bypass attempts, protected removal and concurrent link/removal or route creation. |
| Model/service | Strict parsing of known required fields, coordinates, enums, revisions and civil dates; ignore additional unknown object keys at every nesting level; exact RPC parameter mapping; no requests before authentication; no fallback after malformed responses. |
| State | Zero vans/routes, partial setup, backend rejection, unknown write, committed write plus failed reload, stale results after session/fleet change, and restored app reading persisted configuration. |
| Widgets | Van create/edit, explicit owner-driver action, route field selection/order, school/campus/city disambiguation, overnight schedules, retained field errors, and responsive/accessible forms. |
| Integration | Configure service coverage -> van -> operator -> route -> schedule, restart, and retrieve the same IDs/values. No trip generation or student allocation is invoked by this flow. |
| Catalog dependency | Real statewide institution coverage and validated coordinates are independently evidenced; mocked test records are not proof of catalog delivery. |

Follow RED -> GREEN -> Refactor. Required release checks include focused tests, full Flutter tests with coverage, at least 80% business/domain coverage, `flutter analyze` with zero issues, `dart format` verification, relevant pgTAP/database lint for the backend extensions, and software-quality-gate. Scanner tooling remains outside the repository; inspect status before and after. Update both READMEs and backend contract documentation. Update `.env.example` only if an approved new runtime key is introduced.

## 11. Consolidation and handoff

The user approved the direction and authorized this consolidation plus the implementation plan. Independent forms, explicit map confirmation, and the owner-driver adapter are retained. Transactional receipts, stale-edit protection, backend coverage invariants, explicit grants, and live PostgREST tests are required acceptance criteria.

[Implementation plan](../plans/2026-09-26-issue-17-owner-fleet-planning.md). The integrated base and catalog source delivery are preparation/release gates, not facts already achieved. No product implementation, merge, database write, commit, or push is authorized by this planning handoff.
