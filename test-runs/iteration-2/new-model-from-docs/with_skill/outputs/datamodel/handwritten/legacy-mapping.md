# Legacy → new model mapping (draft)

Source: S2 (`legacy_trees.sql`, exported 2026-09-30). Target: UrbanTreeCadastre 0.1.0 draft.
Basis for a one-off migration script; to be written once the open questions are settled.

| Legacy | New | Transformation / issue |
|---|---|---|
| `baum.baum_nr` | `tree.tree_number` | 1:1; new `tree.id` = generated UUID (keep a mapping table baum_nr → id for the migration) |
| `baum.art_lat` (free text) | `tree.species_id` → `species` | Clean and deduplicate names, match to the city species list; unmatched names → review list. GBIF match API can propose `gbif_taxon_key` (D-004) |
| `baum.pflanzjahr` | `tree.planting_year` | 1:1 |
| `baum.x`, `baum.y` | `tree.location` | `ST_SetSRID(ST_MakePoint(x, y), 25832)` — **check** that legacy x/y really are EPSG:25832 (A-002); rows without x/y cannot be migrated (location is mandatory) |
| `baum.strasse`, `baum.park` | `tree.site_id` → `site` | Distinct values become `site` rows (type streetSegment / park); a street name is not a segment — segment keys need a GIS join (Q-004). Rows with both or neither → review (A-003) |
| `baum.gefaellt` ('J'/'N') | `tree.status` | 'J' → felled, else standing; felling date/reason unknown for legacy rows (C-001 has scope new, A-015) |
| `baum.angelegt_am`, `geaendert_am`, `geaendert_von` | `tree_history` | Write one initial history row per tree (operation 'I', recorded_at = angelegt_am) and optionally one 'U' row with geaendert_am/geaendert_von |
| `kontrolle.id` | `inspection.id` | New UUID; keep mapping table for measures |
| `kontrolle.baum_nr` | `inspection.tree_id` | via baum_nr mapping; rows without tree → review |
| `kontrolle.datum` | `inspection.inspection_date` | 1:1 |
| `kontrolle.kontrolleur` (name text) | `inspection.inspector_id` → `staff_member` | Distinct names become staff members (personal data!); empty names → placeholder staff member "unknown (legacy)" because inspector is mandatory |
| `kontrolle.vitalitaet` | `inspection.vitality_class` | 1:1 (1–5); depends on Q-001 — if the scale changes to Roloff 0–3, a value mapping is needed |
| `kontrolle.stammumfang` | `inspection.trunk_circumference` | 1:1 (cm assumed) |
| `kontrolle.hoehe` | `inspection.height` | 1:1 (m) |
| — | `inspection.crown_diameter` | not in legacy → NULL |
| `kontrolle.maengel` (comma list) | `inspection_defect` rows | Split by comma, trim, map to `defect_type` codes; **severity is unknown in legacy data** but mandatory → decide a default or make severity voidable (open) |
| `massnahme.id` | `measure.id` | New UUID |
| `massnahme.kontrolle_id` | `measure.inspection_id`, `measure.tree_id` | tree via the inspection; measures without inspection have no tree → review |
| `massnahme.art` | `measure.measure_type` | Map distinct values to codes (Q-003) |
| `massnahme.faellig` | `measure.due_date` | mandatory; NULL → review |
| — | `measure.order_date` | not in legacy → use inspection date (or due date) as fallback |
| — | `measure.priority` | not in legacy → default `normal` |
| `massnahme.erledigt` | `measure.completion_date`, `measure.status` | erledigt set → done, else ordered |
| `massnahme.firma` (text) | `measure.contractor_id` → `contractor` | Distinct names become contractors (deduplicate spelling variants) |
