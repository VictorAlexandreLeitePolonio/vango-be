# Cycle 1 — Multi-Tenant Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement VanGo's multi-tenant foundation including profiles, fleets, memberships, multiple roles per membership, auditing, RLS, and three transactional RPCs.

**Architecture:** Flutter clients execute simple reads and patch operations via Data API governed by minimal column grants and RLS policies. Fleet creation, status transitions, and role assignments execute via PostgreSQL RPCs; privileged helper functions reside in `private` schema.

**Tech Stack:** Supabase Auth, PostgreSQL 17, Data API / PostgREST, PL/pgSQL, RLS policies, pgTAP, Supabase CLI.

**Spec:** `be-tech-plan.md`, sections 4, 8, 9, 12, 13; `CONTRIBUTING.md`, sections 2-7, 13.

## Global Constraints

- The fleet represents the tenant; no cross-tenant operation across `fleet_id` is permitted.
- Cycle 1 creates strictly `profiles`, `fleets`, `fleet_memberships`, `fleet_membership_roles`, and `audit_events`.
- New users join existing fleets in Cycle 2; in this cycle, `create_fleet` assigns the initial owner.
- The `auth.users` trigger creates a minimal profile; `full_name` starts NULL.
- Anonymous access (`anon`) is denied across all tables and RPCs.
- Data API handles simple reads and `PATCH` operations; RPC handles multi-table transactions.
- Do not create Edge Functions, Cron jobs, Realtime channels, buckets, marketplace endpoints, vans, routes, trips, notifications, or maps.
- Do not trust client-supplied JWT claims or role parameters for authorization.
- Explicit RLS policies and grants are delivered together; `authenticated` receives minimum required column access.
- `SECURITY DEFINER` functions enforce `set search_path = ''` and fully qualified objects.
- All code development strictly follows Test-Driven Development (RED, GREEN, REFACTOR).

---

## Approved API Contracts

### Data API Table Permissions

| Resource | SELECT | INSERT | UPDATE | DELETE |
| --- | --- | --- | --- | --- |
| `profiles` | Own profile | Denied | Own `full_name`, `phone`, `avatar_path` | Denied |
| `fleets` | Active membership fleets | Denied | Fleet owner; allowed admin columns | Denied |
| `fleet_memberships` | Own membership or fleet owner | Denied | Denied | Denied |
| `fleet_membership_roles` | Own roles or fleet owner | Denied | Denied | Denied |
| `audit_events` | Fleet owner | Denied | Denied | Denied |

### RPC Functions

```text
create_fleet(
  p_name text,
  p_slug text,
  p_description text default null,
  p_logo_path text default null,
  p_status text default 'draft'
) returns uuid

set_fleet_member_roles(
  p_membership_id uuid,
  p_roles text[]
) returns text[]

set_fleet_membership_status(
  p_membership_id uuid,
  p_status text
) returns text
```

### Error Codes

| Code | Trigger Condition |
| --- | --- |
| `unauthenticated` | Missing JWT or NULL `auth.uid()` |
| `email_unverified` | Attempting fleet creation without verified email |
| `forbidden` | User lacks owner role on targeted tenant |
| `membership_conflict` | Invalid membership or role set |
| `invalid_input` | Invalid name, slug, or role list |
| `invalid_status` | Unpermitted status transition |
| `last_owner` | Attempting demotion/removal of last active fleet owner |
| `slug_conflict` | Duplicate fleet slug |

---

## Deliverable Directory Structure

```text
supabase/
├── config.toml
├── migrations/
│   ├── <cli>_create_foundation_tables.sql
│   ├── <cli>_create_profile_triggers.sql
│   ├── <cli>_create_authorization_helpers.sql
│   ├── <cli>_create_foundation_rls.sql
│   ├── <cli>_create_fleet_rpc.sql
│   ├── <cli>_create_membership_rpcs.sql
│   └── <cli>_create_foundation_audit.sql
├── seed.sql
└── tests/
    ├── _helpers.psql
    └── database/
        ├── 001_profiles.test.sql
        ├── 002_tenancy_rls.test.sql
        ├── 003_create_fleet.test.sql
        ├── 004_member_roles.test.sql
        ├── 005_membership_status.test.sql
        ├── 006_fleet_updates.test.sql
        └── 007_audit_events.test.sql
```

---

## Tasks Overview

- **Task 1:** Revalidate Cycle 0 Foundation.
- **Task 2:** Create Core Tables, Constraints, and Indexes.
- **Task 3:** Implement Profile Creation Triggers.
- **Task 4:** Create Authorization Helper Functions.
- **Task 5:** Implement Row-Level Security (RLS) Policies.
- **Task 6:** Create `create_fleet` RPC.
- **Task 7:** Implement Membership Status & Role RPCs.
- **Task 8:** Configure Audit Logging Triggers.
- **Task 9:** Implement Local Mock Seed Data (`seed.sql`).
- **Task 10:** Final Cycle 1 Verification & Quality Gate.
