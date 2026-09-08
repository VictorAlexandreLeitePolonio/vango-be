# Cycle 2 — Marketplace and Linkings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver the empty school catalog, commercial fleet coverage, student profiles, guardians, marketplace discovery, link requests, invitations, and active links with multi-tenant isolation, privacy, and auditing.

**Architecture:** Flutter uses the Data API strictly for simple reads and RLS-protected updates. Database Functions handle student creation, invitations, status transitions, derived roles, and link creation.

**Tech Stack:** Supabase Auth, PostgreSQL 17, Data API / PostgREST, PL/pgSQL, RLS policies, pgTAP, Supabase CLI.

**Spec:** `docs/superpowers/specs/2026-09-06-ciclo-2-marketplace-vinculos-design.md`.

## Global Constraints

- Do not seed schools or universities in migrations, `seed.sql`, or scripts.
- pgTAP test fixtures must remain transactional and disappear upon test `rollback`.
- Do not create external importers, catalog admin UI, Edge Functions, Cron jobs, Realtime channels, Storage buckets, or Flutter code.
- Do not implement vans, drivers, routes, schedules, capacity checks, availability, or waitlists in Cycle 2.
- Preserve applied migrations from Cycles 0 and 1; use `supabase migration new` for all changes.
- Fleet owners do not create student records. Primary guardians create minor dependents; adult students create their own records.
- Invitations expire after 14 days, store tokens exclusively as SHA-256 hashes, and enforce matching verified email addresses upon acceptance.
- Approved requests or accepted invitations establish direct links.
- Derived `guardian` and `student` roles track source provenance to preserve manual roles.
- `SECURITY DEFINER` functions enforce `set search_path = ''` and fully qualified objects.
- Public responses and audit logs omit PII (emails, raw tokens, street addresses).

---

## Approved Domain Schema

### New Tables

| Table | Primary Responsibility |
| --- | --- |
| `schools` | Global catalog of schools and university campuses |
| `fleet_service_cities` | Cities commercially served by a fleet |
| `fleet_service_schools` | Institutions commercially served by a fleet |
| `students` | Minor dependents and adult students |
| `student_guardians` | Primary and secondary guardians of minor students |
| `student_guardian_invitations` | Secondary guardian invitations |
| `fleet_join_requests` | Marketplace link requests and accepted invitation history |
| `fleet_enrollments` | Active or ended links between fleets and students |
| `fleet_invitations` | Fleet owner invitations to guardians or adult students |
| `fleet_membership_role_sources` | Role provenance for effective user roles |

---

## Deliverable Directory Structure

```text
supabase/
├── migrations/
│   ├── <cli>_create_cycle_2_schema.sql
│   ├── <cli>_create_cycle_2_authorization.sql
│   ├── <cli>_create_marketplace_functions.sql
│   ├── <cli>_create_student_functions.sql
│   ├── <cli>_create_guardian_functions.sql
│   ├── <cli>_create_join_request_functions.sql
│   ├── <cli>_create_enrollment_functions.sql
│   └── <cli>_create_fleet_invitation_functions.sql
└── tests/
    ├── _helpers.psql
    
