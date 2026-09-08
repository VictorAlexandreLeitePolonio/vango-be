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
| 3 | Fleet & Planning | Not started | — |
| 4 | Daily Operations | Not started | — |
| 5 | Push Notifications | Not started | — |
| 6 | Map Tracking & Route Optimization | Not started | — |

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
- `supabase db advisors --local --type all --level warn --fail-on error`: PASS, zero warn/error issues;
- Inspection of grants/RLS/privileged functions: PASS, RLS enabled across all 10 domain tables.

## Cycle 3 — Fleet and Planning

**Status:** Not started

**Log:** No implementation deliverables recorded.

## Cycle 4 — Daily Operations

**Status:** Not started

**Log:** No implementation deliverables recorded.

## Cycle 5 — Push Notifications

**Status:** Not started

**Log:** No implementation deliverables recorded.

## Cycle 6 — Map Tracking and Route Optimization

**Status:** Not started

**Log:** No implementation deliverables recorded.
