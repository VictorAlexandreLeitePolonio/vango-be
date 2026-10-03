# Sao Paulo Institution Catalog: Prerequisite Design

**Status:** Initial prerequisite design for #17; user-approved coverage requirements, proposed delivery approach awaiting review.
**Date:** 2026-09-26
**Consumer:** [Owner fleet planning #17](2026-09-26-issue-17-owner-fleet-planning-design.md).

## 1. Required outcome

Provide real, searchable public and private schools and higher-education campuses throughout Sao Paulo state, including the interior. The owner filters institutions by cities served by the fleet and explicitly links a selected institution. Every available institution has validated coordinates. Failed automatic location resolution is corrected administratively before publication; no unvalidated result is made selectable.

Coverage means the eligible institutions in an identified, dated official source snapshot. It does not mean a few seeded examples or institutions near the capital. Publish the source date and per-city/type coverage evidence. An unresolved institution remains visible in the administrative report, not silently discarded or counted as covered.

## 2. Verified starting point and source evidence

The repository already has `public.schools`, official provider/ID uniqueness, school and higher-education types, `search_schools`, fleet-school links, and owner-scoped coverage RLS. Coordinates are currently nullable. The README explicitly describes an empty real catalog and deferred regional loading. This design does not claim to have inspected the remote database or loaded data.

Official publication pages checked on 2026-09-26:

- [INEP basic-education microdata](https://www.gov.br/inep/pt-br/acesso-a-informacao/dados-abertos/microdados/censo-escolar) lists the 2025 release updated in July 2026.
- [INEP higher-education microdata](https://www.gov.br/inep/pt-br/acesso-a-informacao/dados-abertos/microdados/censo-da-educacao-superior) lists a 2024 release.
- [MEC's national course and institution registry](https://www.gov.br/mec/pt-br/politica-regulacao-supervisao-educacao-superior/cadastro-nacional-de-cursos-e-ies) is a reference for official higher-education identity. The acquisition path must be verified rather than assumed to be a public REST API.

These pages establish publication sources, not that a particular archive contains every required street/campus/coordinate field. No archive dictionary or full SP dataset was imported during this planning turn. The existing research in `docs/research/2026-09-06-catalogo-escolas-brasil.md` is useful context, but its provider pricing, licensing, and API capabilities must be rechecked before choosing a geocoder.

## 3. Proposed minimal approach

Use a repeatable administrative batch: official source files -> normalized SP institution records -> coordinate validation/correction -> reviewed import into the existing `schools` catalog. Use standard-library CSV/ZIP processing and PostgreSQL loading where possible. No permanent ETL server, search-engine service, school-creation UI, or app request to INEP/e-MEC is needed.

This deliberately replaces the earlier research's proposed secondary on-demand search index with one persisted catalog, consistent with the user's statewide loading requirement. An on-demand index would add a second identity/search store; querying providers live would place app availability on external endpoints. Neither is recommended for this delivery.

Keep downloaded datasets, import manifests, pending/rejected reports, and generated SQL outside the Git repository. Version only source adapters, validation/import code, small synthetic fixtures, and operating instructions. Do not put production institutions into the local mock `seed.sql` or download data during database migrations.

## 4. Discovery gates before an executable import plan

1. Inspect each selected archive's actual dictionary and a small sample. Record filename, release/version, checksum, encoding, official ID, operational status, municipality, address fields, and location availability. Confirm public/private coverage and state filtering from actual columns.
2. For higher education, identify a stable offering-location/campus identifier and its address. An institution headquarters or course code is not automatically a campus ID. If the released file lacks this granularity, obtain a documented official location source; do not fabricate `emec` IDs or merge campuses by institution name.
3. Establish a coordinate acquisition method whose actual coverage, persistence permission, cost, and operating limits are verified for the chosen source. Prefer usable official coordinates; automated matching must not accept a similar name alone. No new paid provider or self-hosted service has been selected by this design.
4. Validate source address fields against existing required schema columns. Missing CEP/street/municipal code is reported or corrected from evidence; never default to Sao Paulo city, a generic neighborhood, fabricated number, or a city centroid to satisfy constraints.

Failure of a gate blocks claims of statewide catalog readiness. It does not require blocking independent #16 development or frontend tests with synthetic fixtures. This source-discovery work is separate from the implementation of the #17 forms.

## 5. Identity, coordinates, and publication

Normalize provider IDs without converting numeric-looking identifiers to lossy numbers. Preserve provider + official location ID as the stable key. For schools, use the official school identity; for higher education, preserve the campus/offering-location distinction. Reimports keep existing `schools.id` values so routes and enrollments retain their references.

A publication candidate contains the existing required school fields plus validated latitude/longitude and provenance: source release, original identifier, coordinate source/evidence, validation timestamp, and administrative reviewer identity when applicable. Latitude/longitude must be finite, in legal bounds, and consistent with the institution's actual municipality/address. Bounds alone are not evidence of a correct point. Prefer the entrance used for transport when an administrative correction identifies it.

Pending/ambiguous locations remain in the administrative batch report outside the selectable catalog. A privileged operator corrects the normalized record, records the evidence, reruns validation, and republishes only accepted rows. Owners cannot modify global catalog identity or coordinates through #17.

Enforce the publication rule at the backend search/link boundary as well as in the importer: no null/non-finite/unvalidated coordinates in a selectable result. Existing legacy records with unresolved locations must not leak through another institution search or be accepted in a newly created route. The implementation design must select the smallest provenance storage that makes this rule enforceable; private validation metadata keyed by school ID is preferred to adding administrative details to public search responses.

Administrative corrections to a school already used operationally must preserve started/completed snapshots and use the existing future-trip reconciliation rules where applicable. Coordinate correction is not an enrollment school transfer, and import code must not update `fleet_enrollments.school_id`.

## 6. Search and fleet coverage

Reuse `search_schools(p_query, p_city_ibge_code, p_institution_type, p_limit, p_offset)` with its existing maximum page size of 50. Return official name, type, physical location/address, municipality, and validated coordinates. Preserve safe public institutional data boundaries; no students or fleet-private route data enter this catalog.

Provide a municipal selector from authoritative SP source/municipal data. The fleet chooses its service cities; searches default to one chosen city and optionally filter `school` / `higher_education`. Empty results mean no match for those filters, never demonstration schools. Campus/address details distinguish identically named institutions. Adding a service-school link does not automatically grant permission to modify the institution.

## 7. Import safety and coverage evidence

Each batch supports validation-only output before any write and an idempotent apply against explicit reviewed records. Upsert by stable official key, maintain original IDs, and preserve administrative coordinate corrections unless a reviewed replacement is supplied. Report duplicate/conflicting IDs. Missing records in a later file do not automatically delete referenced schools or prove closure; confirmed inactive institutions leave the historical record intact and cease to be available for new planning.

The manifest records eligible source count, accepted/published count, unchanged/updated count, unresolved coordinates, rejected fields, and duplicate identities by municipality and institution type. Maintain separate public/private and school/higher-education summaries. Every eligible source record must be reconciled to a published row or an explicit pending/rejected outcome. Remaining eligible pending records mean statewide coverage is incomplete.

Release evidence includes an independent sample of interior municipalities and multiple campuses of the same higher-education institution, exact source-to-database counts, repeat-import stability, and tests that unavailable records cannot be selected by API callers. A successful import transaction alone is not evidence of geographic completeness.

## 8. Tests, boundaries, and remaining decisions

TDD covers state/type filtering, non-ASCII names, encoding, preserved identifiers/leading zeros, campus distinction, duplicate IDs, missing mandatory fields, invalid/non-finite/swapped coordinates, evidence requirements, idempotent reimport, administrative correction preservation, source disappearance, safe inactive handling, and non-owner publication denial. Synthetic fixtures must not require paid provider calls. Real-data validation is a separate documented administrative check.

The exact higher-education location source and coordinate resolver remain acquisition decisions to settle with sample evidence. This draft does not approve a provider, promise complete geocoding from the official archives, or silently reduce the user's coverage requirement. No catalog loader, migration, dataset download, data write, or new GitHub issue was created during this design work.
