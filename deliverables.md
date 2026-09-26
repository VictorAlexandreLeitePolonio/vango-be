# VanGo Backend — Deliverables Log by Cycle

This file records only features, files, migrations, and validation test results that have been completed. Plans and design specifications remain in implementation documents and do not count as completed deliverables.

## Update Guidelines

- Update a cycle entry only after implementation and planned validations are fully executed.
- Record actual CLI commands executed and real test outputs; do not mark unexecuted validations as passed.
- Report any deviations between the implementation plan and final outcome.
- Never include secrets, tokens, private URLs, or personal data.
- Do not modify historical records of completed cycles to represent subsequent plans.

## Summary

| Cycle | Scope | Status | Completed On |
| --- | --- | --- | --- |
| 0 | Local Setup & Environment | Completed | 2026-09-05 |
| 1 | Multi-Tenant Foundation | Completed | 2026-09-05 |
| 2 | Marketplace & Linkings | Completed locally | 2026-09-06 |
| 3 | Fleet & Planning | Backend validated; see pending items below | 2026-09-08 |
| 4 | Daily Operations | Backend validated; see pending items below | 2026-09-08 |
| 5 | Push Notifications | Backend validated; see pending items below | 2026-09-08 |
| 6 | Map Tracking & Route Optimization | Backend validated; see pending items below | 2026-09-08 |

## Cycle 0 — Local Setup & Environment

**Status:** Completed

**Completed On:** 2026-09-05

**CLI:** Supabase CLI 2.116.0.

**Delivered Scope:** Reproducible local Supabase development environment with Docker, private schema inacessible to `anon` and `authenticated` roles, and pgTAP infrastructure test suite. No domain entities or API routes created.

**Artifacts:**

- `supabase/config.toml` and `supabase/.gitignore`, generated via `supabase init`;
- `supabase/migrations/20260905224114_create_private_schema.sql`;
- `supabase/seed.sql`, without domain records;
- `supabase/tests/database/000_environment.test.sql`.

**Migrations:** One local migration applied: `20260905224114_create_private_schema`. No migrations applied to remote environment.

**Validations:**

- `supabase --version`, `supabase init --help`, `supabase start --help`, `supabase test db --help`: Executed successfully;
- Docker Desktop active; `docker version` and `docker info`: Executed successfully;
- `supabase init`, `supabase start`, `supabase status`, and `supabase db reset`: Executed successfully;
- RED test prior to migration: Failed as expected because `private` schema did not exist;
- GREEN test post migration: 3 pgTAP tests passed;
- `supabase test db`: 1 test file, 3 tests, result `PASS`;
- `supabase db lint --local --schema public,private --fail-on error`: Zero schema errors;
- `supabase db advisors --local --type all --fail-on error`: Zero issues;
- Database table check: 0 domain tables;
- `git diff --check`: No output.

## Cycle 1 — Multi-Tenant Foundation

**Status:** Completed

**Completed On:** 2026-09-05

**Delivered Scope:** Local multi-tenant foundation with five relational entities, automatic profile creation upon Auth sign-up, `fleet_id` tenant isolation, multi-role membership support, three transactional RPC functions, sanitized audit logging, and local mock seed data.

**Artifacts:**

- `supabase/config.toml`, with `api.auto_expose_new_tables = false`;
- Seven Cycle 1 migrations created via `supabase migration new`;
- `supabase/seed.sql`, containing five test users, two fleets, and mock memberships (`@example.test`);
- `supabase/tests/database/000_environment.test.sql`;
- `supabase/tests/database/001_profiles.test.sql` through `007_audit_events.test.sql`;
- `supabase/tests/_helpers.psql`.

**Entities:** `profiles`, `fleets`, `fleet_memberships`, `fleet_membership_roles`, and `audit_events`, featuring foreign keys, status/slug/role constraints, membership indexes, and enabled RLS policies.

**API Contracts & Access:** PostgREST Data API permits restricted `SELECT` and `PATCH` operations strictly on approved profile and fleet columns. Public RPCs: `create_fleet`, `set_fleet_member_roles`, and `set_fleet_membership_status`. Direct table inserts/deletes remain denied.

**Security:** `anon` holds zero access to tables or RPCs. `authenticated` receives explicit grants only. Private helper functions reside in `private` schema with an empty `search_path`. Fleet owners read audit logs for their own fleet; audit logs are immutable for standard users.

**Executed Validations:**

- `supabase db reset`: PASS;
- `supabase test db`: 8 files, 59 pgTAP tests, PASS;
- `supabase db lint --local --schema public,private --fail-on error`: Zero errors;
- `supabase db advisors --local --type all --fail-on error`: Zero issues;
- `supabase migration list --local`: 8 local migrations in sequence;
- SQL Inspection: Five tables, grants/RLS, and nine functions verified;
- `git diff --check`: Zero whitespace issues.

## Cycle 2 — Marketplace and Linkings

**Status:** Completed locally

**Completed On:** 2026-09-06

**Delivered Scope:** Empty global school catalog, commercial city/institution coverage, minor dependent and adult student registration, primary and secondary guardians, public search functions, marketplace join requests, hashed-token invitations, direct invitation linking, request approval/rejection/cancellation, derived role sources, RLS policies, and sanitized audit logs.

**Scope Exclusions Preserved:** No real schools or universities seeded; zero importers, external APIs, Edge Functions, email dispatch, Flutter code, vans, drivers, routes, capacity checks, or waitlists implemented.

**Artifacts:**

- Migrations `20260905224114_create_private_schema` through `20260906211805_create_fleet_invitation_functions` (17 total local migrations);
- `supabase/tests/database/008_cycle_2_schema.test.sql` through `016_cycle_2_audit_privacy.test.sql`;
- `supabase/tests/_helpers.psql`, updated with mock transactional test fixtures;
- `README.md`, `be-tech-plan.md`, and project documentation updated for executed scope.

**Entities:** `schools`, `fleet_service_cities`, `fleet_service_schools`, `students`, `student_guardians`, `student_guardian_invitations`, `fleet_invitations`, `fleet_join_requests`, `fleet_enrollments`, and `fleet_membership_role_sources`. `schools` catalog remains empty post reset and seed.

**RPC Functions:** `search_schools`, `search_marketplace`, `list_fleet_join_requests`, `get_fleet_invitation`, student creation/updates, guardian/fleet invitations, request submission/decision/cancellation, invitation accept/decline/cancel, and enrollment termination. Critical functions enforce `SECURITY DEFINER`, empty `search_path`, verified email check, locks, and `PGRST` error codes.

**Security:** Transactional tables reject direct client writes (`anon`/`authenticated`); owners administer coverage for their fleet only; address details omit PII after purpose fulfillment; invitation tokens stored exclusively as SHA-256 hashes; derived roles track sources to preserve manual roles; audit events omit PII.

**Executed Validations:**

- `supabase db reset`: PASS;
- `supabase test db`: 17 files, 176 pgTAP tests, PASS;
- `supabase migration list --local`: 17 local migrations in sequence;
- `git diff --check`: PASS;
- `supabase db lint --local --level warning --fail-on error`: PASS, zero schema errors;
- `supabase db advisors --local --level warn --fail-on error`: PASS, zero warn/error issues;
- Inspection of grants/RLS/privileged functions: PASS, RLS enabled across all 10 domain tables.

## Cycle 3 — Fleet and Planning

**Status:** Implemented and validated locally.

**Delivered Scope:** Vehicles (vans) with global license plate uniqueness, driver invitations and roles, routes with ordered schools, finite schedules, seat reservations across all route direction combinations, arrival-order queue handling, and schedule updates. Approval reserves all requested seats atomically.

**Artifacts:** Seven migrations (`20260907235802_cycle_3_vans` to `20260907235814_cycle_3_projections`), test suites `017` to `023`, test fixtures, and concurrency harness. Runbook: [docs/operations/ciclo-3-production.md](docs/operations/ciclo-3-production.md).

**Validations:** 151 Cycle 3 assertions and 7 real concurrency tests passed. Integrated test suite revalidates Cycles 0–2.

## Cycle 4 — Daily Operations

**Status:** Implemented and validated locally.

**Delivered Scope:** Fleet owner calendar configuration, idempotent trip generation, cutoff deadlines and closures, owner exceptions, attendance tracking, driver/van substitutions, operational incidents, and synchronous reconciliation.

**Artifacts:** Eight migrations (`20260907235815_cycle_4_calendar` to `20260907235829_cycle_4_jobs`), test suites `024` to `031`, operations harness, and inactive Cron orchestrator job. Runbook: [docs/operations/ciclo-4-production.md](docs/operations/ciclo-4-production.md).

**Validations:** 193 operational assertions, 12 orchestrator/Cron assertions, and 18 timezone-aware resource release assertions passed; 4 real concurrency races verified.

## Cycle 5 — Push Notifications

**Status:** Implemented and validated locally; real device integration pending.

**Delivered Scope:** Persistent in-app notification inbox with per-recipient read status, device tokens, revalidated recipients, unidirectional messaging, operational events and reminders, queue lease and retry policies, FCM worker with OAuth and PII-free payload.

**Artifacts:** Five migrations (`20260907235831_cycle_5_inbox` to `20260907235838_cycle_5_worker_job`), test suites `032` to `037_notification_worker_job`, claim concurrency tests, Deno `notification-dispatch` Edge Function, and environment examples. Runbook: [docs/operations/ciclo-5-production.md](docs/operations/ciclo-5-production.md).

**Validations:** 129 domain assertions, 15 worker job assertions, and claim concurrency tests passed; 28 Deno tests (OAuth, FCM, dispatch) passed with typecheck, lint, and format.

**External Dependencies Pending:** Remote project requires FCM credentials (`FCM_PROJECT_ID`, `FCM_CLIENT_EMAIL`, `FCM_PRIVATE_KEY`, `NOTIFICATION_WORKER_SECRET`).

## Cycle 6 — Map Tracking and Route Optimization

**Status:** Provider-independent scope implemented; map/ETA provider integration pending.

**Delivered Scope:** Authenticated GPS telemetry, per-assignment history, 30-second sampling, current position storage, private Realtime channels with epoch revocation, privacy-safe projections, idempotent offline sync, trajectory CAS, manual contingency, 30-day retention, and ETA/proximity infrastructure.

**Artifacts:** Five migrations (`20260907235840_cycle_6_locations` to `20260907235848_cycle_6_alerts_retention`), test suites `037_locations` to `041`, TypeScript contracts, SQL concurrency tests, and native WebSocket harness. Runbook: [docs/operations/ciclo-6-production.md](docs/operations/ciclo-6-production.md).

**Validations:** Real WebSockets verify private delivery, cross-tenant denial, client broadcast blocking, and role revocation.

**Offline Contract:** Client offline queues use `sync_trip_events` both online and upon reconnection, preserving command, sequence, and capture timestamps.

**Approved Pending Items:** Selection, budget, and integration of map, geocoding, and ETA providers.

## Integrated Validation & Release Log

Local: 41 migrations reset; 850 pgTAP assertions across 44 files passed; 45 Deno tests passed; typecheck, lint, and format passed; 14 real PostgreSQL concurrency races passed; real WebSocket tests passed.

Remote SQL Deployment (2026-09-08): `npx supabase db push` successfully applied 25 pending migrations to the remote Supabase project (`njjeopcxhnkeszukaoma`). Remote history confirmed: 41 migrations, ending at `20260907235848`. Zero public tables without RLS, zero `SECURITY DEFINER` functions without search_path. Fleets and schools remain empty without remote seeds. FCM secrets, Edge Function deployment, device testing, and map provider integration remain pending.

## Sprint PRD #10 — Owner Fleet Student RPCs

**Status:** Applied to the linked VanGo project on 2026-09-24, including a forward-only replay correction.

**Migration:** `20260924104811_prd_10_owner_fleet_student_rpcs.sql` adds immutable owner-registration command receipts and the `create_fleet_managed_student` and `list_fleet_students` RPCs. Registration requires valid coordinates and an active covered school; it creates the student, enrollment, contact, and sanitized audit event atomically. The list returns active enrollments from both source types with an owner-only privacy projection.

**Replay correction:** `20260924105909_prd_10_registration_replay_after_coverage_change.sql` moves receipt comparison before mutable school and age checks. The first migration remains unchanged after deployment.

**Observed validation:** Local `supabase db reset` passed; focused pgTAP files `022`, `045`, and `046` passed 35, 66, and 65 assertions respectively after the correction. The two-session registration race returned the same IDs with one student, enrollment, contact, and audit event. Local database lint had no errors in the new functions; local advisors reported no issues. `git diff --check` passed. The full database suite was not run for this task.

**Commands executed:** `supabase db reset`; `psql -h 127.0.0.1 -p 54322 -U postgres -d postgres -X -v ON_ERROR_STOP=1 -f supabase/tests/database/{022_schedule_changes,045_fleet_managed_student_model,046_owner_fleet_student_rpcs}.test.sql` (each file separately, with local credentials supplied); `python3 supabase/tests/concurrency/fleet_student_registration.py` with explicit local `PGHOST`, `PGPORT`, `PGDATABASE`, and `PGUSER`; `supabase db lint --local --schema public,private --fail-on error`; `supabase db advisors --local --type all --level error --fail-on error`; and `git diff --check`.

**Remote verification:** The linked project was `njjeopcxhnkeszukaoma` (VanGo). Each dry run showed exactly its corresponding Task #10 migration pending. `supabase db push --linked --skip-vault` applied both in order; remote history lists `20260924104811` and `20260924105909`. Read-only catalog queries confirmed both receipt columns, the check and unique index, both RPCs, authenticated-only execution grants, and replay before mutable validation in the corrected function. No remote write RPC or test fixture was invoked.
