# Issue #11 — Authenticated Owner Fleet Context

**Status:** Initial design for review
**Issue:** [fix(flutter): resolve authenticated owner fleet context](https://github.com/VictorAlexandreLeitePolonio/vango-be/issues/11)
**Scope:** Flutter owner entry point and fleet dashboard

## Goal

An authenticated fleet owner opens the dashboard for a fleet returned by `get_my_access_context()`. The app never chooses an owner fleet from a fixed UUID, onboarding intent, or a client-maintained role alone. A user with no active owner fleet sees a truthful access state, and an account change cannot reveal data loaded for the previous user.

## Current flow and gap

`AuthGate` already requests `getMyAccessContext()` after login and session restoration. `AccessContext.fleetAccess` contains fleet IDs and roles. The home screen currently opens the named dashboard route without passing a fleet. That route constructs `FleetOwnerDashboardScreen` with a fixed fleet ID. The dashboard then reads fleet data using that ID, while `FleetService` can replace read failures with empty or local sample data.

The existing access-context RPC and model remain the source of owner membership. This issue does not add a second authentication or fleet-context store.

## Design

### Resolve the owner fleet

Filter `AccessContext.fleetAccess` to entries whose roles contain `AccountRole.owner`. Ignore `accountRoles` and `onboardingIntent` when deciding which fleet ID can enter owner management; those fields may control presentation but do not identify an authorized fleet. Treat repeated entries for the same fleet ID as one option.

- **One owner fleet:** Select it automatically and pass its ID to the dashboard.
- **Several owner fleets:** Require the user to choose one before opening the dashboard. Keep the choice in the authenticated home flow and pass the selected ID explicitly. The selector shows stable fleet identifiers from the response; no extra fleet-name lookup is required for this issue.
- **No owner fleet:** Show a Portuguese empty/access message in the owner entry area. Do not open the dashboard or load owner data. An onboarding intent of fleet owner alone does not grant access.

The selected ID must still belong to the current access context at navigation time. Route arguments are navigation data, not proof of authorization; Supabase RLS/RPC authorization remains authoritative for every query and mutation.

### Route and session lifecycle

Make the dashboard require an explicit fleet ID; remove its fixed default. The owner entry passes the chosen ID through the route. The dashboard route rejects missing or invalid arguments with a Portuguese access state instead of constructing a dashboard for a fallback fleet. Entering the route directly must not bypass the current session and owner-fleet check.

When the authenticated user changes, signs out, or loses owner access on a refreshed context, clear the selection and remove or invalidate any open fleet dashboard. A dashboard opened for one user must never remain visible under another user's session. Reset dashboard lists and loading state when its fleet changes; discard responses from an older load after a newer fleet/session selection or disposal. Session restoration waits for access context before offering owner navigation.

Reuse `AuthGate`'s request-generation handling for context loads. Any additional route-level lifecycle handling should be limited to keeping a pushed owner screen tied to the current user and fleet; do not introduce a global state framework.

### Loading, empty, and error states

Keep the current loading state while access context is fetched. Preserve the existing retry path when that fetch fails. Distinguish a successful response with no owner fleet from a failed fetch.

For an authenticated owner dashboard, a failed fleet read or mutation must reach a visible Portuguese error with retry where appropriate. An actual empty result displays an empty state. Do not render local sample records or silently translate a network/permission failure into an empty list. Limit service changes to methods exercised by this owner path; wider mock and fallback cleanup belongs to its separate task.

## Affected boundaries

| Existing unit | Responsibility in this change |
| --- | --- |
| `AuthGate` | Load access context after login/restoration and invalidate stale responses on auth changes. |
| `AuthenticatedHomeScreen` | Derive owner fleets from the current context, present zero/one/many states, and navigate with a selected ID. |
| `AppRoutes` / dashboard entry | Accept an explicit fleet ID and guard direct navigation. |
| `FleetOwnerDashboardScreen` | Load only the selected fleet, clear stale data, and present real empty/error states. |
| Owner methods in `FleetService` | Preserve real failures and avoid sample data on the authenticated owner path. |

No database migration, RPC contract change, new dependency, or student/guardian marketplace redesign is part of this issue. The student registration and marketplace routes retain their separate user flows. Any owner-managed student list reached from the dashboard uses the resolved owner fleet ID.

## Acceptance and focused verification

Use TDD for each behavior: run a focused failing unit/widget test, implement the smallest fix, then rerun it. Cover:

1. One active owner fleet opens the dashboard with its returned ID, without a hardcoded ID.
2. No active owner fleet, including owner onboarding intent without membership, shows the access state and makes no owner-data request.
3. Multiple owner fleets require a choice and open the chosen fleet only.
4. Restored sessions wait for access context before owner navigation.
5. Sign-out, account switching, or context refresh removes stale selection and visible fleet data; a late response from the previous user/fleet is ignored.
6. Direct dashboard navigation without a valid current owner fleet is rejected.
7. Access-context and dashboard failures show an error/retry state; successful empty results remain empty and show no sample records.

Run only the affected Flutter unit/widget tests, plus formatting and static analysis required by `CONTRIBUTING.md`. Do not run the complete test suite for this task. Update the relevant Flutter README if the user-visible owner entry behavior or route contract changes.

## Decision and limits

Use the existing access context as the sole source of candidate fleet IDs. A selector is necessary now because the RPC can return multiple owner fleets; silently choosing the first would access an arbitrary tenant. Displaying IDs is an initial identification method until a future task supplies fleet names in the context. The server still enforces authorization, and the client selection only chooses which authorized fleet to request.
