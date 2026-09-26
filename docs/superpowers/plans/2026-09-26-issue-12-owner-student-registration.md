# Issue #12 Owner Student Registration Implementation Plan

## Authorized execution amendment — September 26, 2026

The user authorized implementing #12/#13 in parallel, reviewing/correcting their diffs, and then executing #14. The final scope decision explicitly retains the existing direct provider call and limits implementation to necessary #12/#13 changes. An intermediate Edge Function direction was withdrawn; no new Edge Function, server configuration, dependency, or provider endpoint belongs to this delivery.

The original shared Dart API remains the integration contract. Apply typed failures, honest metadata, timeout/stale-response handling and privacy fixes to the existing Mapbox transport. The user's informed decision permits retaining that direct transport for this bounded work despite the general Edge guidance in CONTRIBUTING section 8. It does not authorize unrelated provider redesign.

The user authorized VanGo to persist the final pickup point but reported that account-specific Mapbox storage entitlement is unknown. That external permission remains unverified; no live provider acceptance or commercial entitlement is inferred. Automated tests use synthetic responses and do not call paid APIs.

The user authorized resetting the disposable local Supabase database and explicitly requested continuing available checks while recording mobile runtime acceptance as pending. The coordinator serializes the shared stack. No commit, push, remote deployment or paid provider probe is included.


> **For agentic workers:** Use superpowers:subagent-driven-development or superpowers:executing-plans as supported by the execution environment. Preserve the selected agentsSwarm coordination method; use the file ownership and dependency gates below. Checkboxes are future instructions. This reviewed document does not authorize implementation, commits, integration, deployment, or paid provider calls.

**Goal:** Let an authenticated fleet owner register minors and adults without existing accounts and retrieve their actual persisted enrollments, with explicit failure and uncertain-outcome handling.

**Architecture:** Extend the existing fleet service and guarded owner dashboard. Preserve Task #10's registration/list signatures and replay semantics. Add residential city validation and a narrowly scoped school-options read contract in a new migration; consume, rather than reimplement, Issue #13's shared address components. Issue #14 owns final integrated acceptance and documentation consolidation.

**Tech Stack:** Existing Flutter/Dart SDK and Supabase Flutter/HTTP packages; PostgreSQL, pgTAP, and the existing Python concurrency harness. No new product dependency, state framework, provider, or generic repository layer.

**Spec:** Issue #12; AGENTS.md; CONTRIBUTING.md; the supplied Issue #12 plan; revised sibling plans 2026-09-26-issue-13-owner-flow-reliability.md and 2026-09-26-issue-14-persisted-mvp-validation.md.

## Review changes and preserved decisions

- Preserved: owner-only minor/adult registration, required coordinates, covered residential municipality, covered active school, no account creation, no marketplace request, and server-authoritative reload.
- Removed from this issue: shared geocoder/autocomplete implementation and their test files. Issue #13 exclusively owns them.
- Moved final README edits and combined real acceptance to Issue #14. This issue still supplies its documentation delta, tests, and evidence.
- Added: school-option reads that do not assume authenticated can join schools; a minimal owner-only RPC is specified below. This is a deliberate bounded addition to the original plan, not a change to either Task #10 signature.
- Added: explicit outcome classification for malformed receipts and ambiguous transport failures; a single in-memory pending command survives back/reopen within the same dashboard session.
- Added: address-number/street edits invalidate the selected coordinates, not only city/search-text changes.
- Added: same-user token refresh preserves a draft/pending command, while actual user/fleet changes revoke it.
- Added: student-tab loading/retry is independent of marketplace/team failures.
- Split local acceptance, remote schema verification, and release readiness. No local result is described as a deployment.

## Global constraints

1. Source, comments, tests, technical documentation, and approved commit messages are US English; UI copy is pt-BR.
2. Work on codex/task-12-owner-student-registration in an isolated worktree. Preserve pre-existing changes, especially vango_app/pubspec.lock, and do not pop/apply another task's stash.
3. No automatic commit, push, merge, cherry-pick, install, migration application, or deployment follows from plan review. During authorized execution, use the coordinator's recorded permissions for each action.
4. Each new behavior/fix follows executable behavioral RED -> minimum GREEN -> refactor. A missing symbol alone is not behavioral evidence. Existing regression tests may start green; do not break code to manufacture RED.
5. Database authorization is authoritative. Route user IDs, selected cities, and local roles are never credentials.
6. No new guardian/student Auth account, student_guardians association, synthetic ID, person matching, or fleet_join_requests row is introduced by registration.
7. Only the generated coverage/options migration may change the backend. Applied #9/#10 migrations are immutable; keep their RPC signatures, canonical hash construction, receipt index, and race-safe subtransaction behavior unchanged.
8. Do not adopt defaults for IBGE, city, UF, coordinates, school, or personal information. A calendar picker may open at a useful date, but the field starts unselected.
9. Automated tests use injected clients/fakes, never live paid geocoding. A mock HTTP response is not proof of database authorization or persistence.
10. Execute version-supported tools with --no-pub where available. Missing prerequisites are explicit blockers, not permission for scanner-driven installation.
11. Full Flutter analysis must report zero issues; business/domain line coverage must be at least 80% with an accounted-for denominator. Required global failures are not waived by focused results.
12. Run the exact software-quality-gate skill available in the execution environment under the user's restrictions: no scanner installs, test creation, source/config/lock edits, or repository-local scanner artifacts. Do not substitute SonarQube or claim the skill ran when it is unavailable.
13. Mapbox transport architecture and storage permission are prerequisite decisions owned through #13's Gate P. Do not present the current direct temporary-geocoding implementation as approved for persistent customer data.

## Review focus

1. A denied school-table join must not masquerade as empty coverage: backend + real authenticated options-read tests in Task 1.
2. A lost/malformed write response may hide a commit: immutable command/payload, no silent new command, and safe back/reopen in Tasks 3–5.
3. Edited address number, street, or city must not retain coordinates for the previous location: Task 4.
4. Logout/fleet change/role revocation versus ordinary token refresh must be distinguished: Tasks 4–5.
5. A committed write followed by list/team/request failure must never be submitted again: Task 5.

## Baseline and integration contract

The supplied plans identify #11 at 0bf471047a39597178d3243d51e17b8b4a0cddc1 and #10 at 935dd1a. These are reference baselines, not a claim about current branch heads. Resolve and record full commit IDs at execution.
Required backend migrations include:

- 20260924002539_prd_9_fleet_managed_student_model.sql
- 20260924104811_prd_10_owner_fleet_student_rpcs.sql
- 20260924105909_prd_10_registration_replay_after_coverage_change.sql
Read the last definition of create_fleet_managed_student: authorization and immutable receipt comparison precede mutable school/age checks. New city checks must follow the same rule.
The supplied #12 file still assigned shared address work to itself. This revision supersedes that assignment. Do not execute its former shared-address Task 4.

## Ownership

| Owner | Exclusive implementation responsibility |
| --- | --- |
| #12 | Coverage/options migration and database fixtures; fleet registration payload/submission state; fleet service/error mapper; owner form/dashboard; associated fleet tests |
| #13 | Shared geocoder, autocomplete, their tests, narrowly coordinated legacy shared-consumer fixtures, and two independently named reliability test files |
| #14 | Combined acceptance record and final edits to README.md, vango_app/README.md, and deliverables.md |

#12 backend/service/model work and #13 shared-address work may proceed in parallel. The real form integration waits for #13's frozen interface. #13 owner reliability tests wait for #12. Both hand off READY FOR INTEGRATION; #14's final acceptance does not require them to have already completed that final acceptance.
Only the coordinator holds the shared Supabase stack lease. This applies to #12 development resets as well as #14 acceptance; separate worktrees alone do not isolate containers/ports. Pause before any database action while another task holds the lease. Database-only #12 work does not wait for #14's final integration; the coordinator can lease the stack to #12 first, then transfer it to #14.

## File map

| File | Responsibility |
| --- | --- |
| CLI-generated supabase/migrations/<timestamp>_owner_registration_city_coverage.sql | City invariant and minimal owner school-options RPC |
| Available next supabase/tests/database/*_owner_registration_city_coverage.test.sql | City validation, options authorization, and replay tests; do not assume prefix 047 is still free |
| supabase/tests/database/046_owner_fleet_student_rpcs.test.sql | Add explicit valid city coverage to existing fixtures only |
| supabase/tests/concurrency/fleet_student_registration.py | Update only required fixture setup; retain protections |
| vango_app/lib/features/fleet/models/fleet_student_registration.dart | Payload, coverage option types, receipt, pure validation |
| vango_app/lib/features/fleet/models/fleet_student_submission_state.dart | One user/fleet-bound in-memory command and outcome; no global/durable queue |
| vango_app/lib/features/fleet/services/fleet_service.dart | Coverage reads, registration, existing owner list; preserve driver behavior |
| vango_app/lib/features/fleet/services/fleet_student_error_mapper.dart | Safe messages and explicit write-failure classification |
| vango_app/lib/features/fleet/screens/fleet_student_registration_screen.dart | Guarded form and command lifecycle |
| vango_app/lib/features/fleet/screens/fleet_owner_dashboard_screen.dart | Form entry, pending-command ownership, independent authoritative student reload |
| Corresponding test/unit/features/fleet/ and test/widget/features/fleet/ files | Behavioral tests for the units above |

Shared address source/tests and READMEs are read-only to this worker. Supply #14 a documentation delta rather than editing its files concurrently.

## Frozen interfaces

### Registration and options

Preserve the exact 20-parameter create_fleet_managed_student contract from the integrated #10 migration. Wire keys are p_fleet_id, p_command_id, p_student_type, p_full_name, p_birth_date, p_postal_code, p_street, p_street_number, p_address_complement, p_neighborhood, p_city_name, p_city_ibge_code, p_state_code, p_latitude, p_longitude, p_school_id, p_shift, p_contact_full_name, p_contact_email, and p_contact_phone. list_fleet_students(uuid) is unchanged.

- FleetStudentType { minor, adult }.
- FleetStudentShift { morning, afternoon, evening, fullTime }, with wire value full_time; UI labels Manhã, Tarde, Noite, Integral.
- FleetServiceCity: immutable String cityIbgeCode, cityName, stateCode.
- FleetServiceSchool: immutable String id, name.
- FleetStudentRegistration: immutable required fields FleetStudentType studentType, String fullName, DateTime birthDate, String postalCode, street, streetNumber, neighborhood, FleetServiceCity city, double latitude, longitude, String schoolId, FleetStudentShift shift, String contactFullName; nullable String? addressComplement, contactEmail, contactPhone.
- Map<String, Object?> toRpcParams({required String fleetId, required String commandId}).
- Map<String, String> validate({required DateTime today}) returns field-keyed pt-BR feedback. It validates input; it does not grant coverage access.
- Future<List<FleetServiceCity>> FleetService.getServiceCities(String fleetId).
- Future<List<FleetServiceSchool>> FleetService.getServiceSchools(String fleetId).
- typedef FleetStudentRegistrationReceipt = ({String studentId, String enrollmentId});.
- Future<FleetStudentRegistrationReceipt> FleetService.registerStudent({required String fleetId, required String commandId, required FleetStudentRegistration registration}).
- Keep FleetService.getOwnerEnrolledStudents(String fleetId) as the owner-list boundary.
New bounded backend read contract: public.list_fleet_service_schools(p_fleet_id uuid) returns table(id uuid, name text). Require authenticated, confirmed, active owner access; missing/out-of-scope fleet returns not_found. Return only active schools covered by this fleet, ordered by lower(name), id; no published-fleet requirement, residential-city restriction, coordinates, or contact data. Revoke PUBLIC/anon execution, grant authenticated execution, and enforce authorization internally with the established restricted-function pattern.
Why this addition: the reference authorization migration revokes table privileges on schools without granting authenticated SELECT there. Granting access to fleet_service_schools does not itself authorize an embedded schools read. Do not solve this by broadly exposing schools. Verify effective permissions on the integrated local schema; if an already approved equivalent minimal RPC exists there, reuse it and update all three plans' interface references together rather than create a duplicate.

### Shared address contract consumed from #13

Preserve searchAddresses(String) and MapboxPlaceSuggestion constructor fields. Add only the agreed optional widget ValueChanged<String>? onChanged; selection invokes onAddressSelected, not the edit callback. #13 owns failure types and stale-result behavior.
City/UF from the selected suggestion must match the selected covered city using the same documented trim/case rule. Only then use that coverage row's IBGE. Matching is not geospatial verification and must never be described as such. Unknown/mismatched city/UF blocks submission.

### Pending command and error classification

Add a small FleetStudentSubmissionState bound to immutable userId/fleetId, with a phase (idle, submitting, unknown, rejected, committed), optional immutable command/payload snapshot, and optional receipt. It has no network access and no disk persistence. State transitions must reject creation of a new command while an earlier command is unresolved.
Keep the original screen constructor; add optional FleetStudentSubmissionState? submissionState. The dashboard supplies its retained instance; direct construction can create a local instance after authorization. MaterialPageRoute<bool> still returns true only for a validated receipt. Back with an unknown outcome does not return success; the dashboard retains that same command and offers Retomar confirmação do cadastro rather than starting another one.
FleetStudentErrorMapper.message(Object error) remains. Add a narrowly scoped FleetStudentWriteFailureKind classification (definitiveRejection, accessUnavailable, idempotencyConflict, unknownOutcome) in the same error-mapper unit, with classifyWriteFailure(Object error) used by the form. Its signature is static FleetStudentWriteFailureKind classifyWriteFailure(Object error). No generic error/result framework.
A timeout, transport interruption, malformed/empty/multiple success receipt, or unrecognized gateway failure is an unknown outcome, not proof of rollback. A recognized domain rejection returned by the actual RPC (including its sanitized registration_failed) is a definitive rejection. Permission loss invalidates access; an idempotency conflict blocks automatic replacement of the command and offers a list review. Never classify only by HTTP 5xx or parse raw message text.

## Execution conventions

Flutter commands run in vango_app; Git/Supabase/Python commands run at repository root. Capture real exit statuses, revision/tree identity, tool versions, and redacted evidence. Planning runs no tests.

## Task 1: Integrate the backend baseline and make coverage reads/writes valid

Files: Owned migration/database files above.
Interfaces: Existing 20-parameter registration RPC; new minimal school-options RPC; unchanged owner student list.

- [ ] Prepare the authorized baseline. Record status and lockfile bytes/diff, resolve dependency SHAs, and obtain the stack lease. The coordinator integrates reviewed #10/#11 changes through the separately authorized method. Do not work indefinitely in a half-finished merge or overwrite either branch's changes.
- [ ] Observe baseline. Inspect actual CLI help, reset only the disposable local stack when authorized, and run the existing full pgTAP runner. Record pre-existing failures rather than attributing them to this issue.
- [ ] RED: school lookup through real authorization. With unpublished fleet A, an active covered school, and owner A's JWT, demonstrate that the proposed direct embedded-table read is not an assumed working contract. Add a behavioral test for the minimal authorized school-options RPC. Include inactive/uncovered school exclusion, owner B/driver denial, and active schools in another municipality still being selectable.
- [ ] GREEN: create the migration once. Run supabase migration new owner_registration_city_coverage; record its generated name. Implement the school-options RPC with explicit safe grants/checks. Preserve table-level restrictions. Test the real PostgREST call as well as SQL authorization; a MockClient response cannot prove this boundary.
- [ ] RED: covered residential city. A fresh valid command for fleet A using a city only covered by B returns invalid_input and changes no student/enrollment/contact/registration-audit counts. Use existing error-extraction helpers; expand SQL includes with the repository runner/helper, not invented filtering flags.
- [ ] GREEN: minimal new-command invariant. After current authentication/owner checks and immutable receipt lookup, require a fleet A city row matching IBGE and normalized city name/UF. Keep the payload hash algorithm unchanged; do not canonicalize old receipts differently. Schools need fleet coverage, not the same municipality as the residence.
- [ ] Repeat RED/GREEN. Cover valid city; absent city; wrong city/UF tuple; null/invalid input; coverage removal before a new command; replay after city or school coverage removal; replay after enrollment termination; permission revoked before replay; conflicting replay payload; unchanged canonical normalization; no publication requirement. Returning an old receipt never reactivates an enrollment.
- [ ] Maintain fixtures and race proof. Seed real coverage explicitly in owned #10/concurrency fixtures, without changing expected receipt/race behavior. Read the actual harness arguments before invoking it. Re-run the full pgTAP runner and bounded local concurrency harness under the lease. Release the lease with cleanup evidence.
- [ ] Review checkpoint. Inspect only the new migration and intended fixture changes. No edit of applied history and no remote push at this checkpoint.

## Task 2: Define payloads and implement honest coverage options

Files: Registration model/tests and fleet service/tests.

- [ ] RED/GREEN: city options. Verify selected columns, fleet filter, strict JSON mapping, deterministic name/IBGE order, successful empty result, malformed row, and backend error propagation. Do not convert permission/network errors to [].
- [ ] RED/GREEN: school options. getServiceSchools calls the authorized minimal RPC, mapping only ID/name. Assert exact fleet argument, empty/invalid/error states, stable ordering, and cross-municipality availability. Do not restore the direct schools join.
- [ ] RED/GREEN: payload serialization. Verify all 20 wire keys against the integrated SQL signature, full_time, YYYY-MM-DD without toUtc(), name trim, lowercase optional email, blank optional values -> null, actual selected IBGE, and exact coordinates. Use syntactically valid UUID fixtures where receipt/identifier validation is exercised.
- [ ] RED/GREEN: pure validation. Check future/invalid dates, exactly 18, day before birthday, PostgreSQL-compatible leap-day cases, contact requirements, finite/bounded coordinates including zero/boundaries, and no prefilled personal data. today is injected for tests; backend remains authoritative near date/timezone boundaries.
- [ ] Review checkpoint. No geography default, account lookup, shared service implementation, or new package enters this change.

## Task 3: Implement strict writes, safe messages, and one pending command

Files: Fleet service/error mapper, submission-state model, and their tests.

- [ ] RED/GREEN: valid receipt. One real RPC request produces exactly one row containing valid student/enrollment identifiers. Reject empty/multiple/malformed rows; never manufacture a receipt. No table inserts, optimistic list mutation, or automatic write retry in the service.
- [ ] RED/GREEN: failure classification. Test recognized domain codes separately from timeout, HTTP transport failure, unknown error text, unexpected gateway status, and malformed HTTP-200 receipt. Unknown outcomes retain command/payload. No SQL/provider text appears in UI or logs. Verify actual PostgREST error decoding against the integrated backend; do not search messages for keywords.
- [ ] Preserve pt-BR copy. `unauthenticated`: `Entre novamente para continuar.`; `email_unverified`: `Confirme seu e-mail para cadastrar alunos.`; `forbidden`/`not_found`: `Seu acesso à frota não está disponível.`; `invalid_input`: `Revise os dados e a cobertura da frota antes de tentar novamente.`; `registration_failed`/unknown generic non-write error: `Não foi possível cadastrar o aluno. Tente novamente.` Unknown write outcomes use the specific confirmation copy below, not this generic fallback. Unknown outcome: Não foi possível confirmar o cadastro. Verifique sua conexão e tente novamente. Idempotency conflict: Não foi possível confirmar este envio. Revise a lista de alunos antes de iniciar outro cadastro. Do not instruct blind reopen/new submission after a conflict.
- [ ] RED/GREEN: submission-state transitions. Double submit creates one command/request. Unknown -> retry sends identical ID/payload; definitive rejection allows correction and a new logical command. Committed -> refresh never returns to submitting. A pending command cannot be overwritten by a different payload. Identity/fleet invalidation removes sensitive state.
- [ ] Review checkpoint. Keep the simple submission state inside this domain. It is neither an Auth store nor durable offline synchronization.

## Task 4: Build the guarded form against #13's completed interface

Files: Owner form/tests; shared address files are read-only.

- [ ] Dependency gate. Obtain #13's reviewed interface and focused evidence before integrated address tests. Backend/model work may precede it; do not copy #13 code into this branch or import absent files into mandatory tests.
- [ ] RED/GREEN: access/options lifecycle. No options/read/write starts before the current session and owner fleet are verified. Cover empty coverage, failed lookup/retry, direct-screen construction, lost membership, stale options, and widget user/fleet changes.
- [ ] RED/GREEN: minor/adult UX. Use pt-BR controls and calendar picker; minor has guardian-contact name; adult uses the current student name as contact; both require a channel. No Auth lookup, hardcoded school, or default personal details.
- [ ] RED/GREEN: address binding. City, search-text, street, or number changes invalidate the selected location snapshot and coordinates immediately. Completing/changing a number after selection requires resolving/selecting the final address again. Preserve user-entered completion fields during this process. Complement-only edits need not change a building's coordinates. Missing optional neighborhood/CEP can be completed without inventing values; an explicitly contradictory location edit requires re-resolution.
- [ ] Validate suggestion provenance. Consume #13's address-only usable suggestions; never accept a municipality centroid as a residence. Known-mismatched city/UF is blocked, not relabeled. Re-key the shared field by the coverage identity and clear controlled text intentionally. An old request cannot repopulate the form after a city/fleet/session change.
- [ ] RED/GREEN: uncertainty and navigation. Bind the form to the dashboard's single submission-state instance. Generate the UUID once before dispatch; use an existing declared public SDK API or a tested private Random.secure-based v4 generator, never an undeclared transitive import. Lock edited payload after dispatch. Retry the retained request even when coverage has since changed; recheck current Auth/owner access, but do not let mutable options/age revalidation prevent receipt recovery. No new command is generated by retry.
- [ ] Back behavior. Prevent accidental dismissal while actively dispatching. When outcome is unknown, back is available with clear copy explaining confirmation is pending; keep the command in the same dashboard's memory and resume it on reopen. No success feedback on back. After process termination or identity loss, this non-durable state is gone: do not promise cross-restart deduplication; require a fresh list review before another manual registration and record that limitation.
- [ ] RED/GREEN: session generations. Revalidate on submit/resume/current Auth events. Same-user token refresh must not destroy an editable draft, discard a pending command, or lose a confirmed result. Actual logout/account/fleet change or owner revocation immediately hides/clears prior data and discards late UI callbacks. Security-context epochs and read-request generations must not be conflated.
- [ ] RED/GREEN: mobile state. Test 320 logical pixels, large text, keyboard scroll, retry labels, focus order, and double tap. No overflow or inaccessible recovery control.
- [ ] Review checkpoint. The screen makes no direct Supabase calls; all network access stays in services. Clear shared cached suggestions through #13's agreed lifecycle boundary when this user/fleet context is invalidated.

## Task 5: Connect an independently loadable student tab

Files: Dashboard and existing widget tests.

- [ ] RED/GREEN: entry. Cadastrar aluno is reachable from an empty authorized student tab. Pass exact fleet/user/Auth/service dependencies and retained submission state through MaterialPageRoute<bool>.
- [ ] RED/GREEN: independent readiness. Pending marketplace requests or team-read failure must not prevent loading/retrying the student list or opening registration once owner authorization succeeds. Separate only the necessary per-section load/error handling; do not redesign unrelated modules or add fake empty data.
- [ ] RED/GREEN: authoritative refresh. A valid receipt triggers a fresh student RPC read. If the server returns a different canonical display name, only that result appears. Keep the student tab selected and do not append the submitted payload locally.
- [ ] RED/GREEN: committed-but-refresh-failed. Display Aluno cadastrado. Não foi possível atualizar a lista. Tente novamente. Retry only the student read. Registration count remains one even if another tab continues failing. Do not turn this into a write error or offer submit again.
- [ ] RED/GREEN: stale versus valid results. A late result from another user/fleet has no effect. A same-user token refresh followed by successful reauthorization may still process the same command's confirmed result. A cancelled form never implies success. Retained unknown command resumes instead of allocating another UUID.
- [ ] Characterize remount. A fresh service instance may prove absence of a local list cache; explicitly label this a mocked regression, not real restart persistence. #14 owns actual process termination/relaunch evidence.

## Task 6: Produce a reviewable integration handoff

- [ ] Run focused owned tests, then formatting, flutter analyze --no-pub, and flutter test --no-pub --coverage on the integrated #12+#13 dependency tree. Account for absent business-layer files as described in #14, not just lines present in LCOV.
- [ ] Under the coordinator's stack lease, verify fresh migration application, full pgTAP, current registration concurrency, lint, and advisors using installed help. Keep local evidence separate from remote history.
- [ ] Run the exact available quality gate with scanner output/tooling outside the checkout. Unavailable skill/tooling is reported explicitly; no unapproved scanner substitutes or installs.
- [ ] Inspect complete owned diff, file inventory, lockfile checksum/diff, and git diff --check. Do not erase other workers' changes or report a clean tree as meaning zero intended uncommitted edits.
- [ ] Supply #13/#14 reviewed source identities, contracts, available test paths, new migration filename/hash, actual gate outcomes, unresolved issues, and README delta. Use READY FOR INTEGRATION, not FINAL ACCEPTANCE PASS.
- [ ] #14 runs combined runtime acceptance. Any product defect returns here for correction, then affected integrated gates rerun. No mandatory circular wait for #14 before this handoff.

## Remote delivery handoff

The new coverage/options contract must eventually exist remotely before the deployed client depends on it. #14 does not deploy. The coordinator records whether the existing user authorization covers this exact new migration; do not invent authorization or silently omit deployment.
After reviewed local/integrated gates and applicable authorization, the designated migration owner checks the actual linked project identity, prerequisite history, frozen migration bytes, backup/recovery readiness, and db push --linked --dry-run. Only expected reviewed pending migrations may proceed. Never remote-reset, include seeds, or run destructive acceptance against the shared remote project.
Verify actual remote history, function signatures, privileges, and the city invariant through read-only inspection after deployment. Freeze applied migration bytes; corrections use another migration. Report three distinct statuses: local integration accepted, remote contract verified, and client release eligible. Pending Mapbox Gate P or runtime blockers prevent the last status.

## Definition of done / references

Owned behaviors and tests pass on the integrated tree; #14 independently confirms real persistence and isolation; documentation is consolidated once by #14; remote status is separately evidenced; no unauthorized Git or data action occurred.
Review basis: supplied Issue #12 plan, especially its coverage/retry/shared-address tasks; repository CONTRIBUTING.md at 0bf471047a39597178d3243d51e17b8b4a0cddc1; 20260906201646_create_cycle_2_authorization.sql and 20260924105909_prd_10_registration_replay_after_coverage_change.sql at the supplied #10 baseline. These sources establish contracts, not proof of execution of this revised plan.

## Local planning provenance

This file incorporates the user-supplied revised plan dated September 26, 2026. External reference verification dates stated above belong to that supplied review; this document update did not independently verify provider documentation, account entitlement, or runtime behavior. Current worktree locations are planning locations, not proof of implementation or validation.

Read the companion plans at these local paths until the coordinator integrates the documents:

- [2026-09-26-issue-13-owner-flow-reliability.md](/Users/victorpolonio123/.codex/worktrees/task-13-reliability/vango-be/docs/superpowers/plans/2026-09-26-issue-13-owner-flow-reliability.md)
- [2026-09-26-issue-14-persisted-mvp-validation.md](/Users/victorpolonio123/.codex/worktrees/task-14-mvp-validation/vango-be/docs/superpowers/plans/2026-09-26-issue-14-persisted-mvp-validation.md)

The #12 planning file remains in the original checkout on `codex/task-12-owner-student-registration`; #13 and #14 already have isolated managed worktrees. Before parallel product execution, satisfy the reviewed #12 isolation requirement without moving, stashing, or overwriting the unrelated original `vango_app/pubspec.lock` change.
