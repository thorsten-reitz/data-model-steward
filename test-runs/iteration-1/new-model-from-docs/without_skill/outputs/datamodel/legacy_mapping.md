# Legacy → new model mapping

Draft v0.1. Implemented in `sql/05_migrate_legacy.sql`. Assumption IDs refer to `ASSUMPTIONS.md`.

## baum → tree

| Legacy column | Target | Rule |
|---|---|---|
| `baum_nr` | `tree.tree_number` | Copied 1:1, so tree tags stay valid. `tree_id` is a new UUID. The sequence continues after `max(baum_nr)`. |
| `art_lat` (free text) | `tree.species_id` | Looked up through `migration.species_map` after normalisation (lower-case, trimmed, single spaces). Exact matches are pre-filled. **The rest must be mapped by hand.** An empty value must also be mapped, for example to an "unknown" entry (A-32). |
| `pflanzjahr` | `tree.planting_year` | Values outside 1700 to the current year become NULL and are logged. |
| `x`, `y` | `tree.geom` | `ST_SetSRID(ST_MakePoint(x, y), 25832)`. A "32" zone prefix is stripped. The load aborts if values are missing or out of range (A-19). |
| `strasse`, `park` | `tree.park_id` / `street_segment_id` | A park is matched by name. A street is matched by name and the nearest segment within 50 m. Park wins if both match. Trees with no match are logged. The original text is kept in `tree.remarks`. |
| `gefaellt` | `tree.status` | `'J'` becomes `felled`. Any other value becomes `living`. |
| (none) | `tree.felled_on`, `felling_measure_id` | Taken from the latest completed felling measure, if there is one. Otherwise NULL and logged (A-20). |
| (none) | `tree.felling_reason_code` | NULL and logged (A-20). |
| `angelegt_am` | `created_at`, `location_since` | Interpreted as Europe/Berlin time (A-24). |
| `geaendert_am`, `geaendert_von` | `updated_at`, `updated_by` | |

## kontrolle → inspection, inspection_defect, staff

| Legacy column | Target | Rule |
|---|---|---|
| `id` | `inspection.inspection_id` | New UUID. Kept in `migration.inspection_map` for traceability. |
| `baum_nr` | `inspection.tree_id` | Looked up by `tree_number`. Rows with no tree, or with a NULL `baum_nr`, are rejected and logged. |
| `datum` | `inspected_on` | Dates in the future or before 1950 are rejected and logged. |
| `kontrolleur` (free text) | `inspector_id` | Each distinct normalised name becomes an inactive `staff` row. Empty values map to "Unbekannt (Altdaten)" (A-33). |
| `vitalitaet` | `vitality_class` | Copied 1:1 (both use 1–5, A-10). |
| `stammumfang` | `trunk_circumference_cm` | Values outside 1–2000 become NULL and are logged. |
| `hoehe` | `height_m` | Values outside 0–80 become NULL and are logged. |
| (none) | `crown_diameter_m` | NULL, because the legacy system did not record it. |
| `maengel` (comma-separated) | `inspection_defect` rows | Split on `,` or `;`. Each part is mapped through `migration.defect_map`. A NULL target means the defect is deliberately dropped, which is logged. Severity is NULL (A-20). |

## massnahme → measure, contractor

| Legacy column | Target | Rule |
|---|---|---|
| `id` | `measure.measure_id` | New UUID, stored in `migration.measure_map`. |
| `kontrolle_id` | `inspection_id`, `tree_id` | Taken from the migrated inspection. Rows with no inspection are rejected and logged, because the tree is unknown. |
| `art` (free text) | `measure_type_code` | Mapped through `migration.measure_type_map`. |
| `faellig` | `due_on` | |
| `erledigt` | `completed_on`, `status` | Not NULL means `done`. NULL means `ordered`. **Old measures that are still open should be reviewed and cancelled where appropriate.** |
| `firma` (free text) | `contractor_id` | Each distinct name becomes an inactive `contractor` row. |
| (none) | `priority`, `ordered_by` | NULL (A-20). |
| (none) | `ordered_on` | Set to the date of the inspection (A-20). |

## Data quality issues seen in the legacy schema

- The species is free text, so there are probably many spelling variants.
- Defects are a comma-separated list with no severity.
- `kontrolle.baum_nr` and `massnahme.kontrolle_id` are nullable, so orphan rows are possible.
- There is no felling date or felling reason. Only a `J`/`N` flag.
- There is no history of location changes, and no record of who created a row.
- Inspector names are free text, so one person can appear under several names.
- The coordinate reference system is not documented (A-19).
