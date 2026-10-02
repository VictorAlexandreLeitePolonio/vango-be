# AI Instructions and Engineering Guidelines (VanGo)

VanGo is a school/university transport MVP: a **Supabase backend** (PostgreSQL + RLS + RPCs + Edge Functions) and a **Flutter client** (`vango_app/`). There is no Node.js server — do not add one without an approved architectural decision.

All agents **MUST** read and strictly follow [`CONTRIBUTING.md`](./CONTRIBUTING.md). Project status and per-cycle deliverables live in [`README.md`](./README.md) and [`deliverables.md`](./deliverables.md).

## Non-Negotiable Rules

1. **TDD (Red -> Green -> Refactor):**
   - Never implement code before writing and executing a failing test.
   - Flutter: unit (`test/unit/`) or widget (`test/widget/`) tests before widgets or business logic.
   - Database: RLS policy changes start with a negative access test plus a positive authorized-role test.
   - Every table with `fleet_id` needs cross-tenant isolation tests (at least two tenants). A test covering only the authorized path does not validate tenant isolation.

2. **Language Policy (Portuguese UI / English Code & Docs):**
   - All code, identifiers, schema objects, comments (`//`, `///`, `--`), docs, commit messages, and test descriptions: **US English (en-US)**.
   - User-facing UI copy in `vango_app` (labels, placeholders, buttons, titles, validator error messages, snackbars, dialog texts): **Portuguese (pt-BR)**, using English identifiers and string keys.

3. **Static Analysis & Linting (Zero Issues Allowed):**
   - After any implementation, run `flutter analyze` inside `vango_app` — **0 issues** required.
   - Check formatting with `dart format --output=none --set-exit-if-changed .`.
   - For Edge Functions, run `deno lint` and `deno check` on modified functions.
   - Before submitting migrations, run `supabase db lint`.

4. **Test Coverage:**
   - Execute `flutter test --coverage` to generate `coverage/lcov.info`.
   - Enforce a minimum threshold of **80% coverage** on business and domain logic layers.

5. **Code Documentation & Comments Standard:**
   - Write clear docstrings (`///` in Dart, JSDoc in TS) for every newly created or updated class, service, model, and public method explaining its purpose, parameters, and return types.
   - Add inline comments (`//`) on non-trivial logic, mathematical computations (e.g., azimuth, bearing, Haversine distance), state management transitions, and UX choices to maintain high code comprehensibility for the team.
   - All code comments and identifiers must remain in **English** (UI copy in **pt-BR**).

6. **Continuous README & Documentation Synchronization:**
   - Whenever new features, architectural components, dependencies, routes, or environment variables are added or modified, update the relevant `README.md` (e.g., `vango_app/README.md` and repository `README.md`) immediately.
   - Document any new `.env` keys, permissions, prerequisites, and instructions on how to test and run the new capabilities.

7. **Git:**
   - Conventional Commits (`feat(scope): ...`, `fix(scope): ...`). Never commit or push without explicit authorization.
   - Check `git status` and `git diff --check` before and after work; keep diffs to authorized files only.

## Key Commands

Run from the repository root unless noted. Database tests require a running local Supabase stack (`supabase start`).

| Task | Command | Location |
| --- | --- | --- |
| Run all pgTAP database tests | `python3 supabase/tests/run_database_tests.py` | root |
| Run a single database test file | `supabase test db --local supabase/tests/database/023_planning_privacy.test.sql` | root |
| Local Supabase status | `supabase status -o env` | root |
| Run all Flutter tests | `flutter test` | `vango_app/` |
| Static analysis | `flutter analyze` | `vango_app/` |
| Format check | `dart format --output=none --set-exit-if-changed .` | `vango_app/` |
| Coverage | `flutter test --coverage` (<- `coverage/lcov.info`) | `vango_app/` |
| Run the app locally | `flutter run --dart-define-from-file=.env` | `vango_app/` |
| Edge Function tests / lint | `deno test`, `deno lint`, `deno check` inside the function dir | `supabase/functions/<function>/` |

Notes:
- `supabase/tests/run_database_tests.py` expands `\ir` includes into temp files, then runs `supabase test db --local`; it never touches remote environments.
- Database suites: `supabase/tests/database/*.test.sql` (pgTAP) and `supabase/tests/concurrency/*` (Python/TypeScript concurrency scripts, each with `*_setup.psql` / `*_cleanup.psql`).
- Edge Function tests are colocated with the function (`index.test.ts`, etc.). No `integration_test/` directory exists in `vango_app` yet.

## Environment & Secrets

- The local stack: `supabase start`, then `supabase status -o env`; local Auth emails are captured by Mailpit.
- `vango_app/.env` (git-ignored) holds client defines: `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY` only. Run Flutter with `--dart-define-from-file=.env`.
- **Never** pass the repository root `.env` to Flutter — it contains server-side SMTP credentials. The service role key must never reach the client.
- Auth callback scheme for Android/iOS: `com.vango.vangoapp://auth-callback/`.

## Architecture Facts

- **Migrations are the only schema tool.** Never create tables, functions, or policies manually in remote projects. Applied migrations are immutable — change schemas only via new files in `supabase/migrations`. `seed.sql` is safe local mock data only.
- **Fleet is the tenant.** Every operational entity carries `fleet_id`; every exposed table has RLS; roles (`owner`, `driver`, `guardian`, `student`) are validated only within the given `fleet_id`. Never trust client-provided roles or UUIDs. One user can hold multiple roles across fleets; navigation reads `public.get_my_access_context()`.
- **RPCs for domain actions.** Flutter may do simple RLS-protected CRUD, but multi-table/state-machine operations (approve links, seat reservations, trip state, role changes) go through RPC functions that validate auth, membership, role, and state transactionally. Domain errors return stable codes (`forbidden`, `email_unverified`, `capacity_exceeded`, `last_owner`, ...) that Flutter maps — never parse error message strings.
- **Privacy-first projections.** The API must never return other passengers' stops, student identities, raw addresses, or route geometries that expose homes; authorization is enforced backend-side, never by hiding UI.
- **Cycle status:** Cycles 0–5 plus the provider-independent portion of Cycle 6 (map/tracking/optimization) are implemented and validated locally; the school catalog is empty, and FCM device setup plus provider integrations are pending.
- **Stack oddity:** root `package.json` is vestigial (only `@supabase/server`); backend logic lives in SQL migrations, pgTAP tests, and the two Edge Functions (`route-calculate`, `notification-dispatch`).
