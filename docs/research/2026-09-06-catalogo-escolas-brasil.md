# Educational Institutions Catalog Research (Brazil)

**Research Date:** September 6, 2026  
**Scope:** INEP/e-MEC, Google Places, Mapbox Search, and OpenStreetMap (Nominatim/Overpass), using exclusively official maintainer documentation and public datasets.

## Executive Summary

For the VanGo MVP, the most reliable and legal architecture is a minimal hybrid approach:

1. **Official Registry Identity:** INEP for basic education (k-12) and e-MEC / Censo da Educação Superior for higher education.
2. **Search Index:** A lightweight local search index built from official annual dataset downloads. The domain table `schools` is populated strictly when a user selects an institution.
3. **Geocoding & Coordinates:** OpenStreetMap coordinates resolved via a self-hosted Nominatim instance or a commercial provider with terms compatible with VanGo, executed strictly post-selection. Queries try the INEP code first (`ref:INEP`) and fall back to official institution name and address.
4. **Fallback Handling:** If no reliable spatial match is found, the institution remains without validated coordinates and does not participate in distance-based filters until manual administrative review. Unvalidated automated spatial matches based on name similarity alone are rejected.

This separation preserves official persistent identifiers, avoids commercial lock-in for core domain data, and keeps `schools` domain record creation on-demand.

The public `nominatim.openstreetmap.org` instance MUST NOT be used for production in VanGo, as its terms of service explicitly mandate self-hosting for vehicle tracking applications.

## Summary Comparison

| Provider | Brazil Coverage | On-Demand Search | Address & Coordinates | Persistence & License | Rate Limits & Cost | Operational Risks |
| --- | --- | --- | --- | --- | --- | --- |
| **INEP / e-MEC** | Censo Escolar covers public and private basic education. Catalog reports over 226,000 schools. e-MEC is the official registry for higher education campuses. | Public name/code search panels exist, but no public versioned REST API endpoint is provided. Official interfaces are annual file downloads and web portals. | School Catalog publishes street address and phone. e-MEC publishes operational addresses. Coordinates are not guaranteed by an API contract. | INEP Data dataset lists Creative Commons Attribution license. Annual downloads preserve official license notices. | Zero per-query charges published. Operational cost is internal: downloading, normalizing, and indexing annual bulk files. | Most authoritative dataset, but updated annually. Internal dashboard endpoints must not be scraped. |
| **Google Places API (New)** | Supports `preschool`, `primary_school`, `school`, `secondary_school`, `university` types with Brazil coverage. | Yes: Autocomplete, Text Search, Nearby Search, Place Details via REST. | Returns formatted address, components, and location coordinates based on field masks. | Inadequate for persistent domain storage: terms prohibit caching/saving Google Maps names and addresses. Place IDs are persistent exceptions. Places content cannot be used with non-Google maps. | Requires billing and API key. Text Search Pro includes 5,000 monthly free calls and costs $32/1,000 requests thereafter. | Mature API but creates legal and commercial lock-in. Place IDs can change over time. Does not satisfy persistent `schools` catalog requirements. |
| **Mapbox Search Box API** | Address and POI search, but official documentation restricts supported geographies to US, Canada, and Europe. **Brazil is NOT supported.** | Yes: `/suggest`, `/retrieve`, `/forward`, `/reverse`. | GeoJSON responses include name, full address, and coordinates. | Search Box data is strictly temporary; position persistence requires custom commercial contracts. | Standard rate limit: 10 req/s. Standard pricing: 2,500 free monthly sessions, then $11.50/1,000 sessions. | Eliminated due to lack of Brazil regional support and default persistence restrictions. |
| **OpenStreetMap + Nominatim** | Approved tags for `amenity=school`, `amenity=college`, `amenity=university`, and `ref:INEP` in Brazil. Community global coverage. | Yes for text/structured search via self-hosted instance or commercial provider. Public instance prohibits autocomplete. | Nominatim returns name, address details, latitude/longitude, `osm_type`, and `osm_id`. | ODbL license with mandatory attribution. Individual geocoding result storage alongside third-party data is permitted provided it does not systematically rebuild OSM. | Software and data can be self-hosted. Public instance enforces 1 req/s absolute limit and forbids vehicle tracking apps. | Excellent enrichment source, but not a primary registry authority. Production requires self-hosted Nominatim. |
| **OpenStreetMap + Overpass** | Tag-based querying for mapped educational establishments in a geographic bounding box. | Technically feasible, but designed for data extraction, not live autocomplete or real-time user searches. | Returns OSM elements, tags, and geometries. | Same ODbL and attribution rules as OSM. Systematic extraction risks derivative dataset classification. | Public instances are shared and free with strict usage guidelines (suggested <100 queries/day). | Public servers can be throttled or unavailable. Not suitable for app critical path. |

## Source Evidence Details

### INEP and e-MEC

- INEP describes Censo Escolar as the primary statistical survey for basic education across public and private institutions: [Censo Escolar](https://www.gov.br/inep/pt-br/areas-de-atuacao/pesquisas-estatisticas-e-indicadores/censo-escolar).
- School Catalog aggregates addresses, phone numbers, and educational offerings for 226k+ schools: [Catálogo de Escolas](https://www.gov.br/inep/pt-br/acesso-a-informacao/dados-abertos/inep-data/catalogo-de-escolas).
- Official annual datasets remain the primary open data format: [Microdados do Censo Escolar](https://www.gov.br/inep/pt-br/acesso-a-informacao/dados-abertos/microdados/censo-escolar) and [Microdados do Censo da Educação Superior](https://www.gov.br/inep/pt-br/acesso-a-informacao/dados-abertos/microdados/censo-da-educacao-superior).
- For transport logistics, higher education identifiers must represent the **offering campus location**, not just central administrative headquarters: [Manual do módulo IES 2024](https://download.inep.gov.br/pesquisas_estatisticas_indicadores_educacionais/censo_da_educacao_superior/orientacoes/manuais/modulo_instituicao_de_educacao_superior_ies_2024.pdf).

### Google Places

- Places API offers Autocomplete, Place Details, Nearby Search, and Text Search: [Places API (New)](https://developers.google.com/maps/documentation/places/web-service/reference/rest).
- Terms forbid caching or saving place content (names, addresses, coordinates) beyond 30 days: [Google Maps Platform Terms](https://cloud.google.com/maps-platform/terms).

### OpenStreetMap & Nominatim

- OSM features approved tags for schools, universities, and [INEP codes in Brazil](https://wiki.openstreetmap.org/wiki/Key%3Aref%3AINEP).
- Public instance usage policy explicitly mandates self-hosting for vehicle/package tracking applications: [Nominatim Usage Policy](https://operations.osmfoundation.org/policies/nominatim/).

## Recommended Schema Contract for Cycle 2

For persistent catalog records in `schools`:

- Basic education: `provider = 'inep'` and `external_id = INEP code`;
- Higher education: `provider = 'emec'` and `external_id = campus location code`;
- `source_updated_at` matching the official publication year/date;
- `geocoder_provider = 'osm'`, `geocoder_external_id = osm_type + osm_id`, and geocoding timestamp when matched;
- Official institution name, type, and address from official registries; latitude and longitude from geocoding service;
- Unique constraint on `(provider, external_id)`.

In production, backend requests call a self-hosted Nominatim instance or licensed commercial provider using `countrycodes=br`. `nominatim.openstreetmap.org` is excluded from production execution paths.
