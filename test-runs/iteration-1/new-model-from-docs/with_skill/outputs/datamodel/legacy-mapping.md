# Legacy schema (S2) → model 0.1.0 mapping

Basis for the data migration. Table/column names on the right are those of the generated `exports/0.1.0/schema.sql`.

| Legacy (S2) | Model element | New column | Transformation / issue |
|-------------|---------------|------------|------------------------|
| `baum.baum_nr` | `Tree.treeNumber` | `tree.tree_number` | 1:1; new `tree.id` = generated UUID (keep a mapping table baum_nr → id during migration) |
| `baum.art_lat` (free text) | `Tree.species` → `Species.botanicalName` | `tree.species_id` | Normalise and match against the species list; unmatched → clean-up list (Q-003) |
| `baum.pflanzjahr` | `Tree.plantingYear` | `tree.planting_year` | 1:1; NULL = unknown |
| `baum.x`, `baum.y` | `Tree.location` | `tree.location` | `ST_SetSRID(ST_MakePoint(x, y), 25832)` — CRS assumed (Q-008) |
| `baum.strasse`, `baum.park` (free text) | `Tree.site` → `Park` / `StreetSegment` | `tree.site_id` | Create one site per distinct name; if both filled, park wins (A-014, Q-008) |
| `baum.gefaellt` ('J'/'N') | `Tree.status` | `tree.status` | 'J' → `felled`, else `standing`; **felling date and reason are missing in legacy** → C-001 requires them: use a migration placeholder (e.g. `felling_date` = `geaendert_am`::date, reason `other`) and flag for review |
| `baum.angelegt_am`, `geaendert_am`, `geaendert_von` | `history` (audit) | `tree_history` | Write one initial history row per tree (`operation` 'I', `recorded_at` = `angelegt_am`, `recorded_by` = `geaendert_von`) |
| `kontrolle.id` | `Inspection.id` | `inspection.id` | New UUID; keep mapping id → UUID for `massnahme` |
| `kontrolle.baum_nr` | `Inspection.tree` | `inspection.tree_id` | Via baum_nr → UUID mapping; legacy FK is nullable — inspections without a tree cannot be migrated (report them) |
| `kontrolle.datum` | `Inspection.inspectionDate` | `inspection.inspection_date` | 1:1 |
| `kontrolle.kontrolleur` (free text) | `Inspection.inspector` → `StaffMember` | `inspection.inspector_id` | One staff member per distinct normalised name; NULL → a staff record "unknown (legacy)" (Q-007) |
| `kontrolle.vitalitaet` | `Inspection.vitality` | `inspection.vitality` | 1:1 if scale is unchanged (Q-002); NULL is not allowed in the new model → decide per case |
| `kontrolle.stammumfang` | `Inspection.trunkCircumference` | `inspection.trunk_circumference` | 1:1 (cm assumed) |
| `kontrolle.hoehe` | `Inspection.height` | `inspection.height` | 1:1 |
| — | `Inspection.crownDiameter` | `inspection.crown_diameter` | New, NULL for legacy data |
| `kontrolle.maengel` (comma-separated) | `Inspection.defects` (DefectFinding) | `inspection_defects` | Split on commas, map each term to a `defect_type` code; **severity is missing in legacy** — assumed `medium` and flagged (review) |
| `massnahme.id` | `Measure.id` | `measure.id` | New UUID |
| `massnahme.kontrolle_id` | `Measure.inspection` | `measure.inspection_id` | Via mapping; NULL values violate the new model (Q-005) |
| `massnahme.art` | `Measure.measureType` | `measure.measure_type` | Map free text (varchar 40) to code list; add missing codes |
| `massnahme.faellig` | `Measure.dueDate` | `measure.due_date` | NULL not allowed → decide (e.g. = completion date) |
| `massnahme.erledigt` | `Measure.completionDate`, `Measure.status` | `measure.completion_date`, `measure.status` | not NULL → `done`, else `ordered` |
| `massnahme.firma` (free text) | `Measure.contractor` → `Contractor` | `measure.contractor_id` | One contractor per distinct normalised name |
| — | `Measure.priority`, `Measure.orderDate` | `measure.priority`, `measure.order_date` | Not in legacy: `normal` and the inspection date as defaults, flagged |
