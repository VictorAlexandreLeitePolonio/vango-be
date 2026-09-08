# VanGo — Development Guidelines

This document defines the non-negotiable engineering rules for the entire VanGo project (Supabase Backend and Flutter Frontend). Every AI coding agent and human developer **MUST read and strictly follow these guidelines before planning and before implementing any code in the repository**. Do not add a Node.js server or a parallel authentication layer without an approved architectural decision.

## 1. Core Principles

- **Mandatory TDD:** Every change or behavior addition strictly begins with an automated test that fails before productive code exists.
- **Strict English-Only Policy:** All source code, variable names, class names, function names, inline comments, docstrings, technical documentation, commit messages, and test descriptions must be written in **US English (en-US)**.
- **Static Quality & Coverage:** No code is accepted without lint validation (zero warnings and zero errors) and test coverage report generation.
- Make the smallest safe change for the feature under development.
- Preserve approved contracts and multi-tenant isolation.
- Use clear names and keep every file, class, migration, and function dedicated to a single responsibility.
- Avoid premature abstractions, code duplication, and client-side authorization logic.
- Handle failures explicitly. Do not use empty `catch` blocks or swallow errors.
- Do not mix unrelated refactorings into the current delivery.
- Record every architectural, security, or domain decision.

## 2. Strict TDD (Test-Driven Development)

Every behavior change in any system layer — **Database/RLS, Edge Functions, or Flutter Frontend** — strictly starts with an automated test. The non-negotiable cycle is:

1. **Red:** Write a focused unit, widget, or integration test and run it. Confirm that it fails specifically due to the absence of the expected behavior (not due to syntax errors or accidental compilation failures).
2. **Green:** Implement only the minimum strictly required code to make the test pass.
3. **Refactor:** Improve readability, architecture, names, and typing while keeping all tests passing green.
4. Repeat the cycle for the next behavior or vertical slice.

Non-negotiable TDD Rules:
- **No Coding Before Testing:** Do not write implementation code prior to executing and verifying a failing red test.
- **No Monolithic Red Test Suites:** Do not create a massive batch of red tests to implement all at once. Work in small incremental steps (*baby steps*).
- **Evidence in Reports:** Retain evidence of the `RED` and `GREEN` cycles in AI execution logs or PR descriptions.
- **Bug Fixes:** Every bug fix begins by writing a test that reproduces the bug before fixing it.
- **RLS and Policies:** RLS policy updates start with a negative access test and a positive authorized role test.
- **Flutter:** Business rules (Controllers, Blocs, Cubits, Repositories, UseCases) and Widget behaviors must be created from automated tests (`flutter test`).

## 3. Testing Strategy, Linting, and Coverage

### 3.1 Database and RLS (PostgreSQL)

Database tests (via pgTAP) must cover:

- Constraints and referential integrity;
- Relevant transactions and concurrency;
- Valid and invalid state transitions;
- Permitted access for each role;
- Denied access across tenants;
- Anonymous calls;
- Usage of known UUIDs from another tenant;
- Audit history immutability;
- RPC functions and their error codes.

Every table containing `fleet_id` requires a test using at least two distinct tenants. A test covering only the authorized path does not validate tenant isolation.

### 3.2 Edge Functions (Deno / TypeScript)

Edge Functions must have unit tests for data transformation, validation, and error handling. External integrations must use fakes or controlled test servers; standard test suites must not consume paid APIs.

Test timeouts, invalid responses, provider limits, idempotent retries, and service unavailability. Secrets must never appear in fixtures, snapshots, or log outputs.

### 3.3 Realtime and Scheduled Jobs

Test authorization on private channels, blocking outside active trips, and rejection of unassigned drivers. Scheduled jobs must be idempotent and tested as invokable functions without relying on real clock progression.

### 3.4 Flutter and Dart (Frontend Mobile)

In the `vango_app` directory, test suites must cover:

- **Unit Tests (`test/unit/...`):** Validation rules, domain models, JSON/DTO mapping, API services, repositories, and state management (Bloc/Cubit/Notifier).
- **Widget Tests (`test/widget/...`):** Rendering of shared components, form visual states, dynamic field validations, click responses, and screen navigation.
- **Integration Tests (`integration_test/...`):** Critical end-to-end user flows (e.g., authentication flow and screen navigation).

### 3.5 Static Analysis and Linting (Mandatory Post-Implementation)

Upon completing any implementation or change, static analysis must be executed and pass with **ZERO tolerance** for errors or warnings:

- **Flutter / Dart:**
  - Command: `flutter analyze`
  - Requirement: **0 issues found** (zero errors, warnings, or pending lints).
  - Formatting: Run `dart format --output=none --set-exit-if-changed .` to guarantee full compliance with the official Dart style guide.
- **Supabase / Edge Functions:**
  - Command: `deno lint` and `deno check` on modified functions.
- **Database:**
  - Command: `supabase db lint` prior to submitting migrations.

### 3.6 Code Coverage

All new functionality must have automated test coverage with generated reports:

- **Flutter / Dart:**
  - Command: `flutter test --coverage`
  - Output: Standardized `coverage/lcov.info` file.
  - **Minimum Threshold:** At least **80% coverage** across business logic layers (`domain/`, `core/utils/`, `blocs/`, `cubits/`, `services/`, `repositories/`).
  - For quick local coverage verification: Use tools such as `lcov` (`genhtml coverage/lcov.info -o coverage/html`) or Dart utilities such as `coverde check 80`.
- **Edge Functions:**
  - Command: `deno test --coverage=cov_profile`.

### 3.7 Final Checklist Verification

Before declaring any phase completed:

- Execute the full relevant test suite (`flutter test`, `deno test`, pgTAP tests);
- Run static analysis (`flutter analyze`, `deno lint`);
- Verify test coverage and ensure all new logic is covered;
- Run code formatting checks (`dart format`);
- Verify migrations from scratch if schema changes occurred;
- Check for temporary logs, secrets, or redundant code comments;
- Ensure all code, comments, and documentation are strictly in **US English**;
- Run `git diff --check`;
- Inspect `git status` before and after completion.

## 4. PostgreSQL Migrations

- Version control all schema changes under `supabase/migrations`.
- Never create tables, triggers, functions, extensions, or policies manually in remote projects.
- Applied migrations are immutable; modify schemas via new migration scripts.
- Use UUIDs or sortable identifiers as documented.
- Explicitly declare `NOT NULL`, `UNIQUE`, `CHECK`, `FOREIGN KEY`, and deletion cascades.
- Index foreign keys, `fleet_id`, and columns frequently referenced in policies and queries.
- Use `timestamptz` for timestamps and store recurring schedules with explicit time zones.
- Prefer soft deletes when an entity is part of operational history.
- Avoid foreign key arrays. Use junction tables such as `route_schools`.
- Preserve snapshots of completed trips; do not derive historical data from mutable record tables.

`seed.sql` must contain mock data safe for local development only.

## 5. Multi-tenancy and RLS

The fleet represents the tenant. Every operational entity must include `fleet_id`, even when inferable from another relationship, strengthening policies, index efficiency, and auditing.

Mandatory Rules:

- Enable RLS on every exposed table;
- Use `auth.uid()` to identify the calling user;
- Validate active membership and assigned role within the same `fleet_id`;
- Never trust roles, user IDs, or tenant IDs passed directly from Flutter;
- Prevent cross-tenant access even if a user provides a valid foreign UUID;
- Expose only sanitized projections in the marketplace;
- Keep student minor data, home addresses, and route details out of public queries;
- Write explicit policies for every required operation; missing policies default to denied access;
- Test `SELECT`, `INSERT`, `UPDATE`, and `DELETE` operations separately where applicable.

Avoid recursive policies between associations and roles. Private helpers may inspect permissions. Functions using `security definer` require:

- Explicit, safe `search_path`;
- Non-exposed schema;
- Default revoked permissions;
- `GRANT` statements restricted strictly to required roles;
- Internal validation of `auth.uid()` and `fleet_id`;
- Dedicated negative access tests.

Never store `service_role` or other secret keys in Flutter.

## 6. Auth and User Profiles

Supabase Auth manages email/password credentials, email confirmations, session tokens, and password recovery. Do not create custom `password_hash`, custom JWT tokens, or custom refresh tokens.

`profiles` extends `auth.users` with domain data. A trigger can initialize minimal profile records, but must not grant permissions based on unverified user metadata.

Users can complete profile setup before email confirmation. However, operations affecting third parties (e.g., creating a fleet, inviting users, requesting student linking) require confirmed emails.

## 7. Database Functions and API Contracts

Use RPC functions for operations that:

- Update multiple tables transactionally;
- Validate capacity limits or schedule conflicts;
- Modify user roles;
- Execute state machine transitions;
- Produce audit records alongside actions;
- Require locking or idempotency guarantees.

Functions must validate authentication, tenant membership, user role, current state, and domain invariants. Return stable data types. Domain errors must return predictable codes, such as:

- `email_unverified`;
- `forbidden`;
- `membership_conflict`;
- `capacity_exceeded`;
- `schedule_conflict`;
- `invalid_transition`;
- `last_owner`.

Flutter applications must map these error codes rather than parsing error message strings. Never expose stack traces, raw SQL error details, or cross-tenant data.

## 8. Edge Functions and Integrations

Use Edge Functions for third-party APIs, push notifications, geocoding, and routing. Do not migrate standard CRUD operations to Edge Functions.

- Validate Supabase JWTs and domain authorization.
- Read secrets exclusively from secure environment variables.
- Configure explicit timeouts and retry strategies.
- Use idempotency keys for repeatable operations.
- Normalize external API responses before returning data to Flutter.
- Log operational context without exposing authorization tokens, full addresses, or raw student coordinates.
- Centralize shared helper code in `supabase/functions/_shared` only when genuine reuse exists.

No third-party service provider may be adopted prior to documented evaluation in the technical plan.

## 9. Realtime and Location Tracking

- Use private channels scoped per trip.
- Authorize channel access by membership, role, and active trip participation.
- Accept location streams exclusively from assigned drivers during active `trip.active` status.
- Broadcast only minimum required coordinates and operational status.
- Never stream student home addresses or residential stop points.
- Enforce location filtering at the backend level; hiding UI markers does not protect data.
- Persist telemetry samples at a lower frequency than live stream feeds.
- Purge raw GPS points after 30 days.
- Retain operational summaries and events according to the technical plan.

## 10. Auditing and Observability

Audit sensitive actions within the same database transaction as the state change. Record tenant, actor, action, entity, and minimal context. Do not copy full payloads into audit `metadata`.

Log operational failures with adequate correlation IDs for diagnosis. Logs must NEVER contain:

- Passwords or tokens;
- API keys;
- Complete home addresses;
- Unnecessary student coordinates;
- Full third-party provider payloads;
- Personal data belonging to another tenant.

## 11. Privacy

Data related to minors and live locations requires default minimization. Every database query must return only fields necessary for the given role and operation.

Guardians and adult students receive van location, ETA, school names, and their own stop location. Only fleet owners and assigned drivers receive the complete operational route. The backend API must never return unauthorized fields with the expectation that Flutter will hide them.

## 12. Git and Code Review

Use short-lived feature branches and strict Conventional Commits formatting:

- `feat(scope): ...`
- `fix(scope): ...`
- `test(scope): ...`
- `refactor(scope): ...`
- `docs(scope): ...`

Do not commit or push without explicit authorization. Preserve unrelated local workspace changes. Inspect `git status` before and after editing, limiting diffs to authorized files.

Code reviews prioritize:

1. **Critical:** Cross-tenant leaks, minor privacy exposure, client secrets, or data corruption;
2. **High:** Contract breakage, authorization bypass, race conditions, or invalid state transitions;
3. **Medium:** Missing error handling, inefficient queries, or historical data inconsistencies;
4. **Low:** Localized maintainability or code clarity issues;
5. **Suggestion:** Non-functional improvements without immediate operational impact.

Avoid superficial code review comments without practical benefit.

## 13. Definition of Done (DoD)

An implementation phase is considered complete and ready for PR/merge only when:

- **TDD Executed with Evidence:** All new behaviors started with a verified failing test (`RED`) prior to productive implementation (`GREEN`);
- **Tests Pass 100%:** Unit, widget, and integration tests pass with 100% success (`flutter test`, `deno test`, pgTAP tests);
- **Strict Lint Verified:** `flutter analyze` reports 0 issues (zero warnings, zero errors) and `deno lint` passes cleanly;
- **Code Formatted:** `dart format` passes without pending changes;
- **Test Coverage Threshold Met:** `flutter test --coverage` (or `deno test --coverage`) achieves the minimum 80% coverage on business logic;
- **100% US English Standard:** All code, file names, identifiers, comments, documentation, and commit messages are strictly in US English (en-US);
- **Clean Idempotent Migrations:** Migrations execute flawlessly on a fresh database instance;
- **Complete RLS Policies:** RLS includes validated positive access and negative isolation test cases across tenants;
- **Typed & Handled Errors:** Failures map to domain error codes;
- **Code Cleanliness:** No secrets, temporary debug logs, commented code, or unreferenced TODOs remain;
- **Clean Git State:** `git diff --check` passes and `git status` contains only files intended for the task.

Do not declare an implementation complete without this empirical evidence.

## 14. Language Standard (English-Only Policy)

The entire repository follows an international code standard. The use of **US English (en-US)** is strictly mandatory across all project scopes:

1. **Source Code:**
   - File and folder names (`user_repository.dart`, `login_screen.dart`);
   - Class, method, function, variable, and constant names (`class VehicleTracker`, `fetchActiveRoutes()`, `final String userEmail`);
   - Database schemas, table names, column names, and triggers (`fleet_id`, `created_at`, `is_active`);
   - Route names and parameters.

2. **Comments and Code Documentation:**
   - All inline comments (`//`), block comments (`/* */`), and docstrings (`///`) must be written in **US English**;
   - Migration notes and SQL comments (`--`) in US English.

3. **Commit Messages and PRs:**
   - Conventional Commits formatted commit messages in US English (`feat(auth): add email and password validation rules`, `test(widget): add widget test for custom text field`);
   - Pull Request titles and descriptions in US English.

4. **Automated Testing:**
   - Group descriptions (`group('AuthRepository', () { ... })`) and test descriptions (`test('should return user when credentials are valid', ...)` or `testWidgets('renders login button disabled when form is empty', ...)`).
