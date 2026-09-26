# Issue #13 Owner Flow Reliability Implementation Plan

## Authorized execution amendment — September 26, 2026

The user authorized implementing #12/#13 in parallel, reviewing/correcting their diffs, and then executing #14. The final scope decision explicitly retains the existing direct provider call and limits implementation to necessary #12/#13 changes. An intermediate Edge Function direction was withdrawn; no new Edge Function, server configuration, dependency, or provider endpoint belongs to this delivery.

The original shared Dart API remains the integration contract. Apply typed failures, honest metadata, timeout/stale-response handling and privacy fixes to the existing Mapbox transport. The user's informed decision permits retaining that direct transport for this bounded work despite the general Edge guidance in CONTRIBUTING section 8. It does not authorize unrelated provider redesign.

The user authorized VanGo to persist the final pickup point but reported that account-specific Mapbox storage entitlement is unknown. That external permission remains unverified; no live provider acceptance or commercial entitlement is inferred. Automated tests use synthetic responses and do not call paid APIs.

The user authorized resetting the disposable local Supabase database and explicitly requested continuing available checks while recording mobile runtime acceptance as pending. The coordinator serializes the shared stack. No commit, push, remote deployment or paid provider probe is included.


> **For agentic workers:** Use superpowers:subagent-driven-development or superpowers:executing-plans as supported by the execution environment. Preserve agentsSwarm coordination and the ownership gates below. Checkboxes describe future work; planning is not authorization for implementation or external actions.

**Goal:** Distinguish real empty address searches from failures, prevent fabricated/stale location data, and keep sensitive owner-onboarding input out of application logs.

**Architecture:** Harden the existing shared geocoder/autocomplete in place while preserving their selection interfaces. #12 owns registration, state, coverage/options, domain errors, and authoritative student refresh. This issue independently checks those owner contracts after integration. #14 owns combined acceptance and documentation, not another implementation.

**Tech Stack:** Existing Flutter/Dart, HTTP MockClient, flutter_test, Supabase Flutter, and the existing Mapbox integration. No new dependency, generic framework, replacement provider, or silently introduced Edge Function.

**Spec:** Issue #13; AGENTS.md; CONTRIBUTING.md; the supplied #13 plan; revised sibling plans 2026-09-26-issue-12-owner-student-registration.md and 2026-09-26-issue-14-persisted-mvp-validation.md.

## Review changes

- Exclusive shared-address ownership is now also reflected in #12; its former competing implementation task is removed.
- Added an address-feature check and removal of fixed geographic search bias: a usable numeric center alone does not establish a residential address.
- Added invalidation for programmatic controller changes, client/service replacement, and late cache writes after clearCache, not only ordinary typing.
- Expanded independent checks to malformed successful write responses, pending-command back/reopen, number edits, token refresh, and marketplace-independent student reload.
- Added Gate P for two external prerequisites: the repository's Edge Function requirement and Mapbox storage permission. Neither is silently waived by this plan.
- Clarified that pre-existing passing checks are regression characterization, and that #13 can hand off READY FOR INTEGRATION before #14's final acceptance.

## Global constraints

1. Branch codex/task-13-reliability; supplied worktree /Users/victorpolonio123/.codex/worktrees/task-13-reliability/vango-be; supplied starting reference #11 0bf471047a39597178d3243d51e17b8b4a0cddc1. Verify actual paths, dirty state, and full revisions at execution; do not assume local access from this document.
2. Current action is plan review only. No implementation, test run, install, commit, push, merge, migration, live provider request, or deployment follows automatically.
3. Each new behavior/fix follows executable behavioral RED -> GREEN -> refactor, one case at a time. Do not manufacture RED for already-correct contracts.
4. US English technical content; pt-BR UI. All modified public classes/methods receive concise English documentation.
5. No #12 production/test edits by #13; report defects to its owner with a reproducer. Missing prerequisites do not authorize a parallel implementation.
6. No broad cleanup of driver trips, Directions, marketplace, or legacy self-registration persistence. Preserve unrelated workspace changes and the Task #10 stash.
7. Use installed tools and --no-pub where supported. No paid provider calls in automated tests. A live configured provider session requires separate authorization and Gate P.
8. Require full relevant Flutter tests, zero analyzer issues, formatting, and >=80% business/domain coverage. Focused shared-component success is not integrated acceptance.
9. Resolve the actual software-quality-gate skill in the executor's environment; do not invent it or substitute SonarQube. Apply scanner restrictions: external artifacts/tooling, no installs, new tests, source/config/lock edits, or repository-local outputs. If unavailable, report its gate as BLOCKED rather than PASS.
10. Never claim that log sanitization protects SDK internals, provider telemetry, or unrelated code. Evidence is limited to exercised application paths.

## Review focus

1. HTTP 200 with malformed data is not a successful empty search: Task 1.
2. A valid coordinate for a city/street centroid is not a resolved residential pickup: Task 2.
3. Old success/error/cache results after edit, number/city change, selection, controller replacement, session invalidation, or disposal must not restore stale state: Tasks 2–4.
4. Raw URL/token/address/contact in a transport exception must not enter public error strings or logs: Tasks 1 and 4.
5. Confirmed write plus failed refresh differs from unknown write outcome: Task 4, with production behavior owned by #12.

## Gate P — prerequisites for real persistent geocoding

### P1. Repository architecture

The supplied baseline CONTRIBUTING.md section 8 routes third-party geocoding through Edge Functions. The existing Flutter service calls Mapbox directly. Hardening that parser does not make this architecture discrepancy disappear.
The coordinator must record one of these outcomes before live persistent acceptance/release:

- an existing approved server-side geocoding boundary is available and a separately scoped integration handoff identifies its exact contract; or
- the user explicitly approves a documented, bounded temporary architectural exception for the current direct client transport, including restrictions and a follow-up owner.
Do not create a new Edge Function, widen this issue into provider deployment, or mark this discrepancy resolved without that decision. Pure shared-component work with injected clients may proceed. #14 reports real-flow/release readiness BLOCKED while P1 is unresolved.

### P2. Rights to store provider results

This workflow persists selected coordinates for future transport. Confirm that the actual Mapbox endpoint/account configuration permits persistent storage. A public token or a successful HTTP response is not evidence of that permission.
The version-specific Mapbox v5 reference distinguishes mapbox.places and mapbox.places-permanent; do not copy a v6 parameter or switch a billable endpoint without verifying the deployed version, entitlement, and user authorization. The review did not inspect the user's Mapbox account.
Record the selected mode and allowed cache behavior before enabling live persistence. Do not treat the static cache as mandatory functionality when the configured mode does not permit it. Keep the clearCache() interface, but adapt/disable result caching consistently with the approved mode and record the intentional behavior change. Never store provider results indefinitely merely because caching was present in the old code.
Automated tests use synthetic provider responses. Missing entitlement blocks real-provider persistent acceptance; it must not be bypassed with invented coordinates or relabeled fixtures. These are prerequisites, not additional providers or hidden deployment tasks.

## Baseline and ownership

At the supplied #11 baseline, the geocoder logs query/raw exception, replaces errors with [], inserts geography defaults, and uses a static cache. Autocomplete has a 400 ms debounce, no visible failure/retry, no request generation, and no edit notification. Its legacy student consumer remains a regression dependency, not persistence proof.

| Owner | Files / responsibility |
| --- | --- |
| #13 | vango_app/lib/features/shared/services/mapbox_geocoding_service.dart |
| #13 | vango_app/lib/shared/widgets/mapbox_address_autocomplete_field.dart |
| #13 | vango_app/test/unit/features/shared/mapbox_geocoding_service_test.dart |
| #13 | vango_app/test/widget/shared/mapbox_address_autocomplete_field_test.dart |
| #13 | New vango_app/test/unit/features/fleet/owner_flow_reliability_test.dart |
| #13 | New vango_app/test/widget/features/fleet/owner_flow_reliability_test.dart |
| #12 | Registration/coverage/submission-state models, fleet service/error mapper, owner form/dashboard, fleet tests, coverage/options migration |
| #14 | Combined acceptance and final READMEs/deliverables |

Read/run vango_app/test/widget/features/student/student_registration_screen_test.dart. Narrow fixture corrections require ownership coordination and must describe real complete suggestions, not retain fake IBGE/defaults or weaken owner persistence assertions. Legacy production fixes remain outside this issue; if an unchanged consumer can now crash, block integration and coordinate that smallest caller fix instead of ignoring it.

## Parallel schedule

- Wave A: #13 Tasks 1–3 run independently while #12 develops owned backend/model/service work. #14 may prepare acceptance tables. No imports of absent #12 files.
- Gate A: Publish exact file inventory, shared interface, revision/tree identity, and observed focused results. #12 consumes this implementation; it does not redo the shared files.
- Wave B: Coordinator integrates reviewed changes through the authorized method. #13 runs Task 4 on that combined tree, writing only its uniquely named reliability tests.
- Gate B: #12/#13 hand off READY FOR INTEGRATION with no hidden failures. #14 owns final same-tree acceptance. This avoids a circular requirement that #13 be finally accepted before #14 can run.
#13 needs no database reset. A shared local-stack lease covers all destructive tests by other workers from the beginning, not just final acceptance.

## Frozen shared interface

Preserve:

```dart
Future<List<MapboxPlaceSuggestion>> searchAddresses(String query);
static void clearCache();
```

Preserve injectable http.Client/MapboxConfig, existing public constructor calls, and all suggestion fields: String placeName, street, streetNumber, neighborhood, cityName, cityIbgeCode, stateCode, postalCode, and double latitude, longitude.
Unavailable textual metadata is '', never S/N, Centro, a default municipality/UF/CEP/IBGE. This provider contract supplies no authoritative IBGE; cityIbgeCode stays empty. #12 may select the matching covered municipality's IBGE only after checking real city/UF metadata.
In the existing geocoder file add:

```dart
enum MapboxGeocodingFailure { timeout, transport, provider, invalidResponse }

class MapboxGeocodingException implements Exception {
  const MapboxGeocodingException(this.failure, {this.statusCode});
  final MapboxGeocodingFailure failure;
  final int? statusCode;
}
```

toString() contains only enum/status. Do not retain raw causes, URLs, queries, bodies, contact values, coordinates, or tokens in the public exception.
Autocomplete adds optional ValueChanged<String>? onChanged. Invoke it once synchronously for user edits, before search scheduling. Selection calls only onAddressSelected. Internal/programmatic text changes may invalidate work without pretending to be a user-edit callback. #12 owns selection/coordinate invalidation in the form, including number changes.
Keep 400 ms debounce and five-second network timeout. Failure copy: Não foi possível buscar endereços. Tente novamente. / Tentar novamente. Successful empty: Nenhum endereço encontrado. Short query is idle. Retry searches the current valid query only, never retries registration.

## Execution tasks

Run Flutter/Dart from vango_app; Git from root. Use real exit statuses and an external evidence directory. Tests use installed fakes/MockClient; no arbitrary sleeps or new framework.

## Task 1: Typed failures, genuine empty results, and safe diagnostics

Files: Shared geocoder and existing unit tests.

- [ ] RED: transport failure. Replace the swallowed-network-error expectation with an assertion for `MapboxGeocodingException` whose `failure == MapboxGeocodingFailure.transport`. Use http.ClientException containing a synthetic sensitive URL. Add only declarations needed to compile the behavioral test; the old implementation must fail because it returns [].
- [ ] Run focused test. flutter test --no-pub test/unit/features/shared/mapbox_geocoding_service_test.dart --plain-name 'propagates typed transport failure'. Record actual missing-behavior failure.
- [ ] GREEN: sanitize and propagate. Catch supported transport/timeouts and return typed errors to the caller. Remove query/cache chatter and raw exception interpolation. A static category/status diagnostic is sufficient; no empty catches and no payload logging.
- [ ] Repeat RED/GREEN: timeout; HTTP 401/429/500 -> provider with status; invalid JSON/non-object envelope/missing or non-list features -> invalidResponse; actual features: [] -> empty success. A malformed row must not leak a raw cast exception.
- [ ] Verify the actual timeout boundary. Besides a MockClient that throws TimeoutException, use an unresolved HTTP future and the existing fake-clock/widget-test facilities to advance through the five-second boundary. Confirm the wrapper produces typed timeout and late completion cannot alter current UI/cache. Do not wait five wall-clock seconds or import an undeclared testing package.
- [ ] Failure/cache tests. Failure followed by success for the same query makes two actual HTTP calls; failures never populate cache. Apply the Gate P-approved successful-cache policy rather than assuming old cache behavior is valid for the configured provider mode.
- [ ] Privacy tests. Capture and restore debugPrint/zone print. On success, failure, invalid body, and applicable cache paths, sentinel query/token/coordinates/contact/body/URL values never appear. Test toString() and observable enum/status separately.
- [ ] Checkpoint. Run the complete geocoder file; record outcomes and Gate P status. No commit without authorization.

## Task 2: Honest metadata and address-quality checks

Files: Same geocoder and unit tests; no fleet service edits.

- [ ] RED: missing metadata. Valid address feature text/center plus empty context yields empty optional strings and empty IBGE, not baseline defaults. Assert every removed fallback explicitly.
- [ ] GREEN: guarded mapping. Use actual provider fields only. Normalize a valid Brazilian region short code to UF; absent/malformed code yields empty UF. Do not convert district/locality into a municipality, and do not overwrite an actual neighborhood with a less precise locality merely due to array order.
- [ ] RED/GREEN: non-SP result. A real-shaped non-SP synthetic fixture preserves its city/UF/postcode while IBGE remains empty. Trim/case normalization never invents municipality identity. Conflicting administrative context is not silently resolved to the selected coverage city.
- [ ] RED/GREEN: address feature, not arbitrary center. Request address-only results; remove unsupported poi and the fixed São Paulo proximity bias. Reject non-address top-level features and known coarse address accuracy (street, intersection, approximate) as unusable pickup suggestions. Do not assume valid coordinate ranges guarantee a house location. Preserve documented provider behavior for usable address points without claiming rooftop certainty.
- [ ] RED/GREEN: coordinate parser. Preserve longitude/latitude order and exact values; accept zero/boundaries; reject nonnumeric/null/partial/out-of-bounds/non-finite center. Use a decodable overflow-number fixture rather than jsonEncode(double.nan) when testing non-finite JSON conversion. Mixed valid/invalid features keep only valid suggestions. A nonempty response with no usable contract-compliant address fails explicitly rather than presenting fabricated data.
- [ ] Cache invalidation. If result caching is permitted and retained, use the effective query/provider configuration and an invalidation generation. A clearCache() followed by a late old HTTP response must not repopulate the old cache. Return defensive/unmodifiable results so consumers cannot mutate shared cached records. Do not add cross-session persistence or a generic cache framework.
- [ ] Regression checkpoint. Run geocoder and legacy student widget tests. Missing IBGE may expose the legacy flow's known limitation; report it, never refill a fake IBGE. Existing constructor compatibility does not alone prove runtime error compatibility.

## Task 3: Reliable autocomplete lifecycle and retry

Files: Shared widget and its new test file.

- [ ] RED: explicit retry. Fake typed provider failure followed by a valid suggestion. Assert safe error text, cleared spinner, no selection callback, then Tentar novamente causes a second call and renders current results.
- [ ] GREEN: local state/helper. Add a private Future<void> _search(String query, int generation) and minimal current-query/error/loading state. Handle typed errors; unexpected injected failures become the same safe UI error with a static diagnostic. Do not echo raw exceptions.
- [ ] RED/GREEN: empty/idle. Distinguish valid empty result from failure and from fewer-than-three-character idle input. Idle/empty states do not offer stale retry or invoke selection callbacks.
- [ ] RED: overlapping results. Start A, edit to B, resolve B then A; cover both late-success and late-error A. Also resolve A during B's debounce window. Assert A affects neither suggestions, error, nor loading.
- [ ] GREEN: generation handling. Increment immediately on every edit, clear obsolete suggestions/error/loading, cancel the previous timer, then notify the parent and schedule the current 400 ms search only while mounted. Guard all asynchronous updates. Selection and disposal invalidate work before any controller/callback side effects.
- [ ] RED/GREEN: all invalidation paths. Cover clearing input; selecting while an older request is pending; disposal; programmatic controller text changes; controller replacement; geocoding service replacement; city-keyed widget replacement; parent unmount during callback; and editing before retry. Reattach/cancel listeners safely and never dispose externally injected controllers/clients.
- [ ] Callback contract. Every user edit emits exactly one onChanged; selecting emits only onAddressSelected. Internal selection text updates cannot instantly invalidate that new parent selection or start a second unwanted search.
- [ ] Mobile checks. At 320 logical pixels and increased text scaling, error and retry wrap without overflow and expose accessible labels. Update the incorrect debounce docstring to 400 ms.
- [ ] Gate A handoff. Run complete shared tests and coordinated legacy regression. Publish interface and exact changed files/evidence to #12/#14 before integration.

## Task 4: Independent owner reliability checks after #12 integration

Files: Only the two new owner_flow_reliability_test.dart files owned by #13.
Interfaces: Consume #12's fleet service registration/options/list, receipt, error mapper/classifier, owner form (including optional submission state), and user/fleet-bound submission state. Read exact integrated signatures; do not invent alternatives or import another test's private fixtures.

- [ ] Dependency gate. Verify both tasks are on the same reviewed integration tree. If #12 is absent, leave this task pending; no skipped/non-compiling imports on the independent branch.
- [ ] Read characterization. Empty list_fleet_students remains empty, exact fleet ID is transmitted, and errors propagate without demo records. These checks may already pass due to #11; report characterization honestly.
- [ ] Write protocol checks. Minor/adult RPC parameters are exact; no table inserts or synthetic receipt. Empty/malformed/multiple success rows classify as unknown outcome. Same caller command/payload after timeout causes a real second HTTP request without generating a new command.
- [ ] Privacy checks. Exercise failed owner read/write and unknown mapper errors with sensitive sentinel data. Assert safe pt-BR copy and no leaking log/toString output. Assign any production defect to #12.
- [ ] Form checks. Failed server write preserves the form without success/navigation/local student. A municipality mismatch or missing city/UF makes zero registration calls; an IBGE-less but otherwise valid matching suggestion uses actual covered-city IBGE.
- [ ] Address edit checks. Select one resolved address, change its number/street, and attempt submission. Old coordinates cannot be sent. Re-selection of the final address is required. Number completion must not silently attach a new address to an old coordinate pair.
- [ ] Outcome checks. Unknown outcome -> back/reopen resumes the same in-memory command; a same-user token refresh does not erase it. A confirmed receipt followed by failed student refresh reports committed-but-refresh-failed and performs read-only retry. Team/marketplace failure does not disable the student path.
- [ ] Authoritative rendering. Submitted name differs from next backend list name; only backend name renders. Cross-user/fleet late results cannot notify or update another session. Link #12's broader lifecycle tests without duplicating its whole matrix.
- [ ] Run both independent files. flutter test --no-pub test/unit/features/fleet/owner_flow_reliability_test.dart test/widget/features/fleet/owner_flow_reliability_test.dart. Mock counts prove client behavior, not server deduplication; #14 separately verifies real committed state.
- [ ] Trace source boundaries. Owner entry -> form -> service -> RPC -> fresh list never uses demo StudentService/legacy driver enrollment fallback. Source inspection supplements runtime tests, not replaces them.

## Task 5: Validate and hand off without circular acceptance

- [ ] Run focused shared/owner tests on the integrated tree, then flutter analyze --no-pub, Dart format check, and flutter test --no-pub --coverage. Account for all required business-layer source files using #14's denominator procedure; require >=80% and report every global failure.
- [ ] Execute the exact available quality gate under scanner restrictions; capture status before/after and keep tooling/reports external. Do not call an unavailable skill PASS or implicitly install a replacement.
- [ ] Inspect owned file diff/status and git diff --check; compare pre-existing artifacts and lockfile state. Do not clean unrelated data or silently broaden ownership.
- [ ] Send #14 the exact interface, source identity, tests, observed results, Gate P decision/evidence, intentional cache behavior, legacy limitations, and README delta. Final README editing is #14's responsibility.
- [ ] Mark independent implementation READY FOR INTEGRATION only with truthful gates; #14 later marks integrated acceptance PASS/FAIL/BLOCKED. Final runtime/deployment evidence is not manufactured from unit results.

## Acceptance trace / external references

Typed failures and no sensitive application output: Task 1. Honest addresses and no fixed geography: Task 2. Stale-query/controller handling and retry: Task 3. No false owner success across real #12 contracts: Task 4. Same-tree gates and handoff: Task 5. Live provider persistence/release readiness: Gate P plus #14.
Review basis: supplied #13 text; CONTRIBUTING.md section 8 and the geocoder at the #11 baseline. Additional external verification used in this revision:

- Mapbox Geocoding v5 reference: https://docs.mapbox.com/api/search/geocoding-v5/ (feature types, accuracy, endpoints; verified September 26, 2026).
- Mapbox Search service documentation: https://www.mapbox.com/search-service (permanent result-storage distinction; verified September 26, 2026).
- Dart Future.timeout: https://api.dart.dev/dart-async/Future/timeout.html (timed-out source work can still complete; verified September 26, 2026).
No user's Mapbox entitlement, implementation test result, local worktree state, or deployment was verified by creating this plan.

## Local planning provenance

This file incorporates the user-supplied revised plan dated September 26, 2026. External reference verification dates stated above belong to that supplied review; this document update did not independently verify provider documentation, account entitlement, or runtime behavior. Current worktree locations are planning locations, not proof of implementation or validation.

Read the companion plans at these local paths until the coordinator integrates the documents:

- [2026-09-26-issue-12-owner-student-registration.md](/Users/victorpolonio123/Desktop/ProjetoPessoal/vango-be/docs/superpowers/plans/2026-09-26-issue-12-owner-student-registration.md)
- [2026-09-26-issue-14-persisted-mvp-validation.md](/Users/victorpolonio123/.codex/worktrees/task-14-mvp-validation/vango-be/docs/superpowers/plans/2026-09-26-issue-14-persisted-mvp-validation.md)
