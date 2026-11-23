# Decisions

All decisions below were made by the modeller on 2026-11-23 **without user confirmation** (user unavailable). They are provisional until confirmed; related assumptions are in open-questions.md.

## D-001 Purposes, targets and languages (2026-11-23)
Context: S1 asks for PostgreSQL/PostGIS for the app and a JSON Schema for the monthly exchange file. Choice: `purposes: [persistence, exchange]`, `targets: [postgres, jsonschema]` (no XSD). Identifiers in English; documentation in English only (A-001). Rationale: matches the request; German can be added as a second documentation language later without structural change.

## D-002 Exchange consumers treated as strict; closed JSON content (2026-11-23)
Context: unknown how the regional agency validates. Options: strict (closed schema) / tolerant. Choice: strict, JSON Schema `unevaluatedProperties: false`. Rationale: safest assumption. Consequence: after release every optional addition counts as breaking for the agency unless we agree on tolerant consumers or a projection (A-012, Q-008).

## D-003 Identity: UUID generated on the device, legacy number kept (2026-11-23)
Context: inspectors work offline on tablets (S1), so trees, inspections and measures must get identifiers without the server. Legacy `baum_nr` is an integer known to staff. Choice: `id` (UUID, client-generated, stable, used in exchange) as primary key of every entity class; `Tree.treeNumber` optional unique integer, assigned by the server at sync, legacy numbers migrated 1:1. Rationale: no sync collisions; familiar number kept. The identifier attribute is called `id` everywhere so foreign keys read `tree_id`, `species_id`, …

## D-004 Species as a reference class, linked to GBIF (2026-11-23)
Options: (a) extensible enumeration/lookup table of names; (b) class `Species`; (c) adopt GBIF Backbone directly. Choice: (b) with optional `gbifTaxonKey`. Rationale: ~900 entries maintained by the arborist team several times a year, own attributes (common name, active flag); GBIF does not model the city's cultivar names as used, but gives partners an unambiguous taxon. Legacy free-text `art_lat` must be cleaned and matched during migration (the GBIF match API can help).

## D-005 Felling as status on Tree; compensation as self-reference (2026-11-23)
Choice: `Tree.status` (standing/felled) + `fellingDate` + `fellingReason`; a replacement tree points to the felled tree (`replacedTree`, 0..1; a felled tree has 0..* `replacementTrees`). Rejected: separate `Felling` class (only two attributes, 1:1); many-to-many replacement (see Q-005).

## D-006 Department code lists as extensible lists (2026-11-23)
`DefectType`, `MeasureType`, `FellingReason` are maintained by the department and change without a model release → `extensible: true` (PostgreSQL lookup tables; JSON Schema open string with known values in `examples`). Closed lists: `TreeStatus`, `VitalityClass`, `DefectSeverity`, `MeasurePriority`, `MeasureStatus`, `SiteType`. Rationale: a new value in a closed list is breaking for strict consumers.

## D-007 Vitality kept on 1–5 scale despite Roloff 0–3 (2026-11-23)
S1 says "1–5 according to the Roloff scale", S2 has `CHECK (vitalitaet BETWEEN 1 AND 5)`, but the published Roloff key has four classes 0–3 (S4). Choice: follow S1/S2 (integer codes 1–5) so legacy data migrates unchanged. Blocking question before release: Q-001.

## D-008 Location corrections as explicit records (2026-11-23)
S1 requires the previous location and the time of correction. Options: rely on the generic audit trail; explicit composition `TreeLocationCorrection`; bitemporal Tree. Choice: explicit composition (previous location, correctedAt, reason, correctedBy) in addition to the audit trail. Rationale: business-relevant, queryable and exchangeable; bitemporal for one attribute is too heavy.

## D-009 Monthly exchange file envelope written by hand (2026-11-23)
`dmtool` generates one JSON Schema with `$defs` per class (root = anyOf over the top-level classes). The monthly file needs an envelope (period, creation time, arrays of species, sites, contractors, trees, inspections, measures). Choice: generated `schema.json` stays untouched; hand-written `datamodel/handwritten/exchange-file.schema.json` references its `$defs`. Not modelled as a class, because that would create a table and foreign keys in the database. Staff members are **not** part of the file (D-011).

## D-010 One Site class with a type instead of Park/StreetSegment subclasses (2026-11-23)
Same attributes as far as known (name, geometry). Choice: `Site` with `siteType`. Can be split later if they diverge.

## D-011 Personal data isolated in StaffMember (2026-11-23)
Inspector names are personal data (S1). Inspections/measures/corrections reference `StaffMember` by UUID only; the name lives in one table. Open data contains no staff reference; the agency file contains only the pseudonymous UUID (A-011, Q-007).

## D-012 Measure references the tree directly, inspection optional (2026-11-23)
S1: measures are ordered "from an inspection"; legacy `massnahme.kontrolle_id` is nullable and there is no tree reference. Choice: `Measure.tree` mandatory, `Measure.inspection` 0..1, rule C-009 keeps both consistent. Rationale: allows measures without inspection (e.g. after a storm), simpler queries and exchange.

## D-013 PostgreSQL mapping and hand tuning (2026-11-23)
dmtool defaults: closed enums → PostgreSQL ENUM types (vitality → integer + CHECK), extensible ones → lookup tables, compositions → child tables with ON DELETE CASCADE, audit → `<table>_history` (jsonb) filled by trigger, logical deletion → `deleted_at`, geometry → `geometry(Point, 25832)`. Physical tuning (GiST/BRIN indexes, history triggers, no-delete rule for inspections, open data view) in `handwritten/tuning.sql`, which survives regeneration.

## D-014 Coordinates in EPSG:25832 in the exchange file (2026-11-23)
The JSON Schema uses GeoJSON geometries. RFC 7946 GeoJSON prescribes WGS 84; the city works in ETRS89/UTM 32N. Draft choice: exchange coordinates in EPSG:25832, declared in the envelope field `crs`, to avoid transformation loss. To be agreed with the agency (Q-008).
