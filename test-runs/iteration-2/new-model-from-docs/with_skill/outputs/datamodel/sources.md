# Sources

| ID | Title | Location | Version/date | Kind | Covers | Authority |
|----|-------|----------|--------------|------|--------|-----------|
| S1 | Urban Tree Cadastre – Requirements | ../requirements.md | v0.3 | prose requirements, use cases UC1–UC5, volumes | scope, all object types, rules, NFRs, privacy | Parks Department |
| S2 | Legacy schema dump (`baum`, `kontrolle`, `massnahme`) | ../legacy_trees.sql | exported 2026-09-30 | PostgreSQL DDL | existing attributes, types, ranges; migration source | Parks Department (legacy system) |
| S3 | GBIF Backbone Taxonomy (species match API; e.g. `Tilia cordata` → taxon key 3152047, verified) | https://api.gbif.org/v1/species/match · https://www.gbif.org/species/{key} | retrieved 2026-11-23 | external taxonomy register | candidate reference for `Species` | GBIF Secretariat (licence to be re-checked before use) |
| S4 | Roloff vitality key (crown-structure vitality classes 0–3), secondary sources found by web search: https://uni-goettingen.de/de/658615.html, https://trees.org.uk/Trees.org.uk/media/Trees-org.uk/Documents/Conference17/WED-05-Andreas-Roloff.pdf | web | retrieved 2026-11-23 | literature / method | meaning of "Roloff scale" in UC2 — conflicts with 1–5 in S1/S2 (Q-001) | A. Roloff (method author) |

## Candidate code lists / vocabularies

| Enumeration / class | Candidate | Proposed verdict |
|---|---|---|
| `Species` (~900 botanical names) | GBIF Backbone Taxonomy (S3); World Flora Online as alternative (not checked) | Keep the city's own list (cultivars, extended by arborists) but **link** each entry via optional `gbifTaxonKey` — D-004. Not adopted until you confirm. |
| `VitalityClass` | Roloff vitality key (S4) | Literature scale is 0–3, requirements/legacy use 1–5 → kept 1–5 for now, Q-001 |
| `DefectType`, `MeasureType` | German FLL guidelines (Baumkontrollrichtlinie, ZTV-Baumpflege) — not verified online; no machine-readable code list with stable URIs known | No reuse proposed; department-maintained extensible lists — D-006, Q-003 |
| `FellingReason`, `MeasurePriority`, `TreeStatus`, `MeasureStatus` | none known | own lists |
