# Issue #11 Authenticated Owner Fleet Context Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Open the Flutter owner dashboard only for a fleet in the current authenticated user's active owner access context.

**Architecture:** Reuse `AuthGate` and `AccessContext`; derive sorted owner fleet IDs in the model and keep the current choice in the home screen. Pass the chosen fleet and user ID through the existing named route. The pushed dashboard independently checks `AuthService.currentSession` and `getMyAccessContext()` before reads and whenever authentication changes. Make its owner service calls surface errors rather than sample data.

**Tech Stack:** Flutter, Dart 3.11, `supabase_flutter`, existing `flutter_test` fakes.

**Spec:** `docs/superpowers/specs/2026-09-24-issue-11-authenticated-owner-fleet-context-design.md`

## Global Constraints

- Keep code, tests, technical documentation, and commit messages in English; user-facing copy is pt-BR.
- Reuse the existing AuthService and access-context RPC. Add no dependency, state framework, backend migration, or RPC contract.
- Follow RED/GREEN with affected tests during implementation. Before completion, run `dart format --output=none --set-exit-if-changed .`, `flutter analyze`, and `flutter test --coverage` in `vango_app`; check at least 80% business/domain logic coverage.
- Do not edit Task #10, #12, or #13 behavior beyond the owner dashboard calls required here. Keep the existing Task #10 stash untouched.
- Review `CONTRIBUTING.md` and the spec before code changes. Keep changes scoped to each task. Do not commit or push without explicit user authorization.

## File map

| File | Change |
| --- | --- |
| `vango_app/lib/features/auth/models/access_context.dart` | Expose sorted, deduplicated owner fleet IDs. |
| `vango_app/lib/features/auth/widgets/auth_gate.dart` | Reset home state when the authenticated user changes; clear old context as a new load starts. |
| `vango_app/lib/features/auth/screens/authenticated_home_screen.dart` | Show zero/one/many owner states and pass selected fleet and user ID. |
| `vango_app/lib/core/routes/app_routes.dart` | Define typed route arguments and reject absent/malformed arguments. |
| `vango_app/lib/features/fleet/screens/fleet_owner_dashboard_screen.dart` | Guard its own route, load only after authorization, and show real error/empty states. |
| `vango_app/lib/features/fleet/services/fleet_service.dart` | Stop swallowing errors and returning sample data in owner reads/actions. |
| Existing auth/model/fleet unit and widget tests | Pin each behavior with focused tests and replace tests that assert sample records. |
| `vango_app/README.md` | Describe authenticated owner selection and dashboard access. |

## Review Focus

1. Duplicate, unordered `fleet_access` rows: one sorted option per owner fleet (Task 1 test).
2. An owner account role or onboarding intent without an owner fleet: no dashboard request (Task 2 test).
3. Direct navigation with a valid-looking fleet ID for another user: no owner read (Task 3 test).
4. Account switch while a dashboard request is pending: old data never appears (Task 3 test).
5. Failed read versus a successful empty response: visible error/retry versus true empty state (Task 4 test).

---

### Task 1: Deterministic owner fleets

**Files:**
- Modify: `vango_app/lib/features/auth/models/access_context.dart`
- Test: `vango_app/test/unit/features/auth/access_context_test.dart`

**Interfaces:**
- Consumes: `AccessContext.fleetAccess`, `FleetAccess.fleetId`, `FleetAccess.roles`, and `AccountRole.owner`.
- Produces: `List<String> get ownerFleetIds` on `AccessContext`, sorted ascending with duplicates removed.

- [ ] **Step 1: Write the failing model test.** Add this test to `access_context_test.dart` using its current imports:

  ```dart
  test('ownerFleetIds filters, deduplicates, and sorts fleet access', () {
    const context = AccessContext(
      onboardingIntent: null,
      accountRoles: {AccountRole.owner},
      dependentStudentIds: [],
      adultStudentId: null,
      fleetAccess: [
        FleetAccess(fleetId: 'fleet-b', roles: {AccountRole.owner}),
        FleetAccess(fleetId: 'fleet-a', roles: {AccountRole.driver}),
        FleetAccess(fleetId: 'fleet-b', roles: {AccountRole.owner}),
        FleetAccess(fleetId: 'fleet-c', roles: {AccountRole.owner}),
      ],
    );
    expect(context.ownerFleetIds, ['fleet-b', 'fleet-c']);
  });
  ```

- [ ] **Step 2: Confirm RED.** Run `flutter test test/unit/features/auth/access_context_test.dart` in `vango_app`; expect a compile failure because `ownerFleetIds` does not exist.
- [ ] **Step 3: Implement the getter.** Add a documented getter on `AccessContext`:

  ```dart
  /// Active fleet IDs with owner access, sorted for stable presentation.
  List<String> get ownerFleetIds => fleetAccess
      .where((access) => access.roles.contains(AccountRole.owner))
      .map((access) => access.fleetId)
      .toSet()
      .toList()
    ..sort();
  ```

- [ ] **Step 4: Confirm GREEN.** Rerun the focused model test; expect PASS. Add the zero-owner case with `accountRoles: {AccountRole.owner}` and empty `fleetAccess`; expect `ownerFleetIds` to be empty.
- [ ] **Step 5: Review.** Inspect `git diff` only for the Task 1 model and test; leave the changes uncommitted.

### Task 2: Home selection and route arguments

**Files:**
- Modify: `vango_app/lib/features/auth/widgets/auth_gate.dart`
- Modify: `vango_app/lib/features/auth/screens/authenticated_home_screen.dart`
- Modify: `vango_app/lib/core/routes/app_routes.dart`
- Test: `vango_app/test/widget/features/auth/authenticated_home_screen_test.dart`
- Test: `vango_app/test/widget/features/auth/auth_gate_test.dart`

**Interfaces:**
- Consumes: `AccessContext.ownerFleetIds`, `AuthService.currentSession`.
- Produces: `typedef OwnerFleetRouteArguments = ({String fleetId, String userId});` in `app_routes.dart`; the home screen passes this record via `Navigator.pushNamed`.

- [ ] **Step 1: Write failing widget tests.** Extend the existing `_context` helper to accept `List<FleetAccess> fleetAccess`. Assert that no owner access shows a Portuguese access message and no management button. With exactly `['fleet-a']`, assert no selector, an enabled management button, and navigation arguments `(fleetId: 'fleet-a', userId: 'user-1')` for the current user. Two unordered owner fleets must yield sorted selector options. Capture `RouteSettings.arguments` with a test `onGenerateRoute` to assert `(fleetId: 'fleet-b', userId: 'user-1')` after choosing `fleet-b`:

  ```dart
  expect(find.byType(DropdownButton<String>), findsOneWidget);
  expect(
    tester.widget<DropdownButton<String>>(find.byType(DropdownButton<String>))
        .items!.map((item) => item.value).toList(),
    ['fleet-b', 'fleet-c'],
  );
  ```

  Re-pump `AuthenticatedHomeScreen` with a context that removes the selected fleet; assert selection clears and navigation is disabled until a valid choice is made. Add an `AuthGate` test for account switching while its previous context request is pending; the new user must see only their own context.

- [ ] **Step 2: Confirm RED.** Run `flutter test test/widget/features/auth/authenticated_home_screen_test.dart test/widget/features/auth/auth_gate_test.dart`; expect the owner selection and route-argument assertions to fail.
- [ ] **Step 3: Implement the smallest home change.** Add the record typedef above. Let the home screen derive options from `ownerFleetIds`, auto-select only when the list has one ID, and clear a no-longer-present selection in `didUpdateWidget`. Show Portuguese zero-owner guidance. Pass the current session user ID and selected fleet to `pushNamed` only when both exist. In `AuthGate`, clear `_accessContext` at the start of a new access load and key the home widget by the session user ID to discard selection across account changes. Keep the existing request ID check for stale RPC responses. Task 3 updates the route builder to consume the arguments and enforce access before reading data.

  ```dart
  Navigator.pushNamed(
    context,
    AppRoutes.fleetDashboard,
    arguments: (fleetId: selectedFleetId, userId: user.id),
  );
  ```

- [ ] **Step 4: Confirm GREEN.** Rerun the two focused widget test files. Confirm the recorded navigation arguments match the chosen fleet and current session user.
- [ ] **Step 5: Review.** Inspect `git diff` only for the Task 2 production files and tests; leave the changes uncommitted.

### Task 3: Independent dashboard guard

**Files:**
- Modify: `vango_app/lib/core/routes/app_routes.dart`
- Modify: `vango_app/lib/features/fleet/screens/fleet_owner_dashboard_screen.dart`
- Test: `vango_app/test/widget/features/fleet/fleet_owner_dashboard_screen_test.dart`
- Test: `vango_app/test/widget/features/auth/auth_gate_test.dart`

**Interfaces:**
- Consumes: `OwnerFleetRouteArguments`, `AuthService.currentSession`, `AuthService.authStateChanges`, and `AuthService.getMyAccessContext()`.
- Produces: `FleetOwnerDashboardScreen({required String fleetId, required String userId, required AuthService authService, FleetService? fleetService})` with no default fleet ID.
- The route `userId` is only a session-change identifier, never a credential. The guard compares it with `AuthService.currentSession` and verifies the fleet's owner role in a freshly loaded `AccessContext` before each owner read.

- [ ] **Step 1: Write failing guard tests.** Replace the dashboard test's default constructor with explicit fleet/user/auth service arguments and a local `FleetService` subclass that records reads. Test named route entry with no arguments or blank IDs: expect the access state and zero reads. Test a matching user but no owner membership: expect the same. Test an owner membership: the dashboard reads only after the context future completes. Open the route, then emit `signedOut` and `signedIn` for another user; expect old data to disappear. Complete an old read after switching accounts and assert it stays hidden. Add a case where a refreshed context removes the owner role.

  ```dart
  service.accessCompleter = Completer<AccessContext>();
  await tester.pumpWidget(MaterialApp(
    home: FleetOwnerDashboardScreen(
      fleetId: 'fleet-a',
      userId: 'user-1',
      authService: service,
      fleetService: recordingFleetService,
    ),
  ));
  expect(recordingFleetService.readFleetIds, isEmpty);
  ```

  Add `dart:async`, `FakeAuthService`, and model imports to the test. Keep a single `Completer` per pending operation and resolve it during the test so `pumpAndSettle` can finish.

- [ ] **Step 2: Confirm RED.** Run `flutter test test/widget/features/fleet/fleet_owner_dashboard_screen_test.dart test/widget/features/auth/auth_gate_test.dart`; expect the new constructor/guard assertions to fail.
- [ ] **Step 3: Implement the guard.** In the existing dashboard state, subscribe to `authStateChanges` and compare the current session user ID with `widget.userId` before displaying data. On entry and same-user `signedIn`, `userUpdated`, or `tokenRefreshed` events, clear lists, show loading, call `getMyAccessContext()`, and require `ownerFleetIds.contains(widget.fleetId)` before `_loadData()`. On sign-out, user mismatch, or lost role, synchronously clear lists and show a Portuguese access-denied state (or pop the route). On RPC failure, clear lists and show an error/retry state. Use one monotonically increasing request counter to ignore late access and fleet-read completions; increment it on auth changes, fleet changes, and disposal. Cancel the stream subscription in `dispose`. The route builder extracts `OwnerFleetRouteArguments`, rejects missing/blank IDs with a Portuguese access-denied scaffold, and passes typed arguments plus the same `AuthService` instance to the dashboard.

  ```dart
  final sessionUserId = widget.authService.currentSession?.user.id;
  if (sessionUserId != widget.userId) {
    _denyAccess();
    return;
  }
  final access = await widget.authService.getMyAccessContext();
  if (requestId != _requestId ||
      !mounted ||
      widget.authService.currentSession?.user.id != widget.userId) return;
  if (!access.ownerFleetIds.contains(widget.fleetId)) {
    _denyAccess();
    return;
  }
  await _loadData(requestId);
  ```

- [ ] **Step 4: Confirm GREEN.** Rerun the focused dashboard/auth tests. Check both `signedOut` and direct `signedIn` account switch while the route remains on top.
- [ ] **Step 5: Review.** Inspect `git diff` only for the Task 3 production files and tests; leave the changes uncommitted.

### Task 4: Truthful owner data, documentation, and final gate

**Files:**
- Modify: `vango_app/lib/features/fleet/services/fleet_service.dart`
- Modify: `vango_app/lib/features/fleet/screens/fleet_owner_dashboard_screen.dart`
- Modify: `vango_app/test/unit/features/fleet/fleet_service_test.dart`
- Modify: `vango_app/test/widget/features/fleet/fleet_owner_dashboard_screen_test.dart`
- Modify: `vango_app/README.md`

**Interfaces:**
- Consumes: the guarded dashboard's selected `fleetId` and existing `FleetService` owner methods.
- Produces: real empty results or propagated errors from `getPendingRequests`, `getFleetDrivers`, `getOwnerEnrolledStudents`, and `decideRequest`; dashboard error/retry and mutation failure feedback. Keep `getEnrolledStudents` behavior for its driver route caller. The owner student list uses the `list_fleet_students` RPC from Task #10, whose migration must be available before this screen is used.

- [ ] **Step 1: Write failing tests.** Use a `FleetService` test double in the dashboard widget test: return empty lists and assert true empty states with no seeded names; throw from a read and assert a Portuguese error plus retry; throw from `decideRequest` and assert no success message. In the unit test, assert unauthenticated/no-client owner reads and decision calls fail instead of returning sample data:

  ```dart
  final service = FleetService();
  await expectLater(service.getPendingRequests('fleet-a'), throwsStateError);
  await expectLater(service.getFleetDrivers('fleet-a'), throwsStateError);
  await expectLater(service.getOwnerEnrolledStudents('fleet-a'), throwsStateError);
  await expectLater(service.decideRequest('request-a', true), throwsStateError);
  ```

  Replace the old unit/widget assertions that require `Carlos` and other local sample records with tests for the actual return/error contract. Preserve focused coverage of approve/reject behavior through an explicit test double.

- [ ] **Step 2: Confirm RED.** Run `flutter test test/unit/features/fleet/fleet_service_test.dart test/widget/features/fleet/fleet_owner_dashboard_screen_test.dart`; expect the new error assertions to fail.
- [ ] **Step 3: Implement truthful states.** For the four owner methods, throw `StateError` when there is no authenticated client. Let RPC/query failures propagate, including invalid response shape, rather than returning `[]`. Use Task #10's owner-scoped `list_fleet_students` RPC for the owner list; do not query `students` through guardian/student RLS or invent coordinates absent from the RPC. Preserve the existing `getEnrolledStudents` behavior for `DriverRouteService`. Remove the local sample return path and local approval mutation from owner methods; preserve unrelated service APIs. In the dashboard, catch read failures to show a retry state, and catch decision failures to show a Portuguese error without success or local mutation. Clear prior lists before each load and keep the Task 3 request counter check. Update `vango_app/README.md` to describe owner selection and access requirements, correcting its existing claim that the dashboard already has a multi-fleet switcher.

  ```dart
  final client = _client;
  if (client == null || client.auth.currentUser == null) {
    throw StateError('Authenticated fleet access required');
  }
  ```

- [ ] **Step 4: Confirm GREEN.** Rerun the two focused fleet tests plus the focused auth/model tests from Tasks 1–3. Inspect `git diff` for unrelated changes and ensure no fixed fleet UUID remains on the owner dashboard path.
- [ ] **Step 5: Run the required final gate.** In `vango_app`, run the three commands below. Inspect `coverage/lcov.info` for at least 80% coverage over the business/domain paths named in `CONTRIBUTING.md`. If a gate fails, fix the relevant scoped code or test and rerun that gate; record any pre-existing failure separately.

  ```bash
  dart format --output=none --set-exit-if-changed .
  flutter analyze
  flutter test --coverage
  ```

- [ ] **Step 6: Run the repository quality gate and review.** Verify `git status` before and after the `software-quality-gate` skill; its tooling must remain outside the repo and must not modify dependencies, lockfiles, tests, or configuration. Inspect the final scoped diff. Do not commit, push, merge, or deploy without explicit user authorization.

## Completion check

Compare each acceptance item in the spec with a passing focused test, then confirm the final Flutter gate and clean branch diff. Report the exact commands and outcomes; keep local validation distinct from a push or deployment.
