# Assumptions and open questions

Draft v0.1, 2026-11-23. Nobody was available to answer questions, so every gap in
requirements v0.3 was filled with an assumption. Each one has an ID (A-xx) that is
referenced in the SQL comments and the JSON Schema. Please confirm or correct them.
Each entry names the file or files that change if an assumption is wrong.

## Questions to answer first

These assumptions have the largest effect on the model or are the most likely to be wrong:

| # | Question | Current assumption |
|---|----------|--------------------|
| 1 | The requirements say vitality "1–5 according to Roloff", but the Roloff scale has classes 0–3. Which scale do inspectors actually use? | A-10 |
| 2 | Does the regional agency want a monthly delta or the full stock each month? Do they prescribe a format, such as GeoJSON in WGS84 or an existing agency schema? | A-23, A-29 |
| 3 | Can the agency receive inspector identities at all? We send a pseudonym, not the name. | A-17 |
| 4 | Are legacy `x`/`y` values EPSG:25832, or an older system such as Gauß-Krüger (EPSG:31467)? | A-19 |
| 5 | Does every tree belong to exactly one park **or** one street segment? Where do the park and segment geometries come from? | A-08, A-09 |
| 6 | Is the required number of compensation trees recorded somewhere, for example in the felling permit? | A-16 |
| 7 | What are the official lists for defects, measure types, priorities and felling reasons? | A-12, A-13, A-15 |

## All assumptions

### Platform and conventions
| ID | Assumption | Rationale / effect |
|----|-----------|--------------------|
| A-01 | PostgreSQL ≥ 15 with PostGIS ≥ 3.3. | Needed for `gen_random_uuid()` in core, `num_nonnulls`, `EXECUTE FUNCTION` syntax and generated columns. |
| A-02 | Identifiers in English snake_case (JSON: camelCase). Display labels are German, with optional English labels in the code lists. | The legacy schema used German names. The new app team and the agency file are easier to read in English. Renaming is purely mechanical. |
| A-03 | The city is in Germany, time zone Europe/Berlin. Timestamps are stored as `timestamptz` and dates are local dates. | Inferred from the German legacy names and EPSG:25832. |
| A-04 | Scope covers trees, inspections, defects, measures, felling and compensation. Out of scope: planting sites or empty tree pits, felling permits, contractor invoicing, tree photos and documents. | Not mentioned in the requirements. They can be added later as new tables without breaking the model. |

### Trees and species
| ID | Assumption | Rationale / effect |
|----|-----------|--------------------|
| A-05 | Each entry in the species list is one botanical name, including any cultivar. Entries are never deleted, only deactivated. A rename is stored as a new entry plus `replaced_by_species_id`. | Old trees and inspections must keep pointing to valid entries. New trees can only use active species (trigger). |
| A-06 | Genus is derived from the first word of the botanical name (generated column). No full taxonomy is kept. | The list has about 900 entries and is maintained by arborists, so a full taxonomy is overkill. |
| A-07 | Trees, inspections and measures have UUID keys that the tablet generates offline. Trees also get a public integer `tree_number`, assigned by the server on sync, that continues legacy `baum_nr`. | Offline capture needs collision-free keys. Field staff need a short number for tree tags. Until sync, a new tree shows "no number yet" in the app. |
| A-08 | Parks (polygons) and street segments (lines) come from the city GIS or street register and are loaded into `park` / `street_segment`. Their geometries are optional so that migration can start with names only. | The requirements only say "park or street segment". |
| A-09 | Each tree belongs to exactly one park or exactly one street segment, never both and never neither. The rule is relaxed for legacy records. | Legacy data had separate `strasse` and `park` text fields, and both may be filled. |
| A-30 | Only the location has a dedicated history table (`tree_location_history`), as the requirements ask. Corrections to species or planting year can be traced through the generic audit log. | Keeps the main tables simple. |

### Inspections
| ID | Assumption | Rationale / effect |
|----|-----------|--------------------|
| A-10 | Vitality is an integer from 1 to 5, as the requirements and legacy data say. The labels in `vitality_class` are placeholders. The Roloff scale is classically 0–3, so this needs confirmation. If the real scale is 0–3, change the CHECK constraints in `vitality_class` and `inspection`, the JSON Schema range and the seed data. | Requirements v0.3 contradicts the standard. |
| A-11 | Trunk circumference is measured at 1.0 m above ground (German FLL practice, not 1.3 m DBH). It is one value per tree. Multi-stem trees are an open point. | This affects comparability with agency data. |
| A-12 | Each defect type occurs at most once per inspection, with one severity. The defect list is department-maintained and can be deactivated but not deleted. Only deadwood, cavity and root damage are confirmed. The rest of the seed list is a proposal. | The requirements give only three examples. |
| A-25 | An inspection can be corrected (UPDATE) but never deleted. Triggers and privileges enforce this, and the audit log records every change with old and new values. Defect lines can be removed within an inspection, and that is audited too. | "must never be deleted; auditors need to see who changed what" |
| A-21 | "Latest vitality" means the vitality class from the most recent inspection that recorded one. | This avoids showing NULL when the last visit was a quick check without a vitality class. |
| A-26 | Measurements (circumference, crown, height) are optional on each inspection because they are not re-measured every year. Vitality is mandatory for new inspections. | This matches how annual visual checks work in practice. |

### Measures, felling, compensation
| ID | Assumption | Rationale / effect |
|----|-----------|--------------------|
| A-13 | Priority is 1 (immediate) to 4 (low), stored in a code list. The labels and target times are placeholders. | Not specified in the requirements. |
| A-14 | Every measure is ordered from an inspection (UC3), so `inspection_id` is mandatory. A status `cancelled` was added because measures cannot be deleted. The contractor can be recorded before completion, but it is mandatory once the measure is `done`. The in-house crew is a contractor row with `is_in_house = true`. | UC3 only describes "ordered → done". |
| A-15 | Felling reasons are a code list: traffic safety, dead, disease/pest, storm, construction, accident, other. Trees that fell in a storm or died are also recorded as `felled`, with the matching reason. | Keeps a single "removed" status. |
| A-16 | Compensation is an n:m link (`tree_replacement`) between a felled tree and the new tree(s), so one new tree can also compensate several felled trees. An optional `compensation_trees_required` on the felled tree lets the view `v_compensation_status` show outstanding obligations. The link is only valid if the old tree is felled and the new one is living, checked at commit. | "must be tracked" implies a required-versus-planted comparison. |
| A-31 | Setting a tree to `felled` is a deliberate user action, done by the app when a felling measure is completed. It is not an automatic trigger, because a felling can also happen without a measure (storm). | Keeps business logic visible. |

### Privacy, audit, publication, exchange
| ID | Assumption | Rationale / effect |
|----|-----------|--------------------|
| A-17 | Inspector and arborist names exist only in `staff`. The agency file carries a stable pseudonym (`P-XXXXXXXXXX`) for the inspector and no orderer. Open data carries no person reference at all. Contractor company names are exported to the agency but not to open data. | "Inspector names are personal data". Sending the pseudonym still lets the agency see that two inspections were done by the same person, which you may or may not want. |
| A-18 | The audit log stores the login of whoever made each change and is readable only by `cadastre_auditor`. Retention is unlimited, matching the 30-year retention of inspections. **The data protection officer should confirm this.** | Personal data kept for a long time. |
| A-22 | The nightly open data set contains only living trees, with public `tree_number` (not the UUID), botanical name, planting year, location in EPSG:25832 plus a WGS84 copy, and latest vitality class. It is built as a materialized view `opendata.tree` and exported by a scheduler such as pg_cron + ogr2ogr. The export file format (GeoJSON / CSV / WFS) is open. | UC5 lists exactly these fields. |
| A-23 | The monthly agency file is a **delta**: all trees, inspections and measures created or changed in the calendar month, judged by `updated_at`. A `full` file is available for the initial load or resynchronisation. Nothing is ever deleted, so the file has no delete records. Changes to defect lines alone must also update the parent inspection; the app does this, so the delta picks them up. | Delta files are about 20k inspections; a full stock would be about 6 M records over time. |
| A-29 | The exchange format is a single UTF-8 JSON document (JSON Schema 2020-12) with header, complete code lists, trees, inspections and measures. Coordinates are EPSG:25832 easting/northing. It is deliberately not GeoJSON, because RFC 7946 GeoJSON requires WGS84. | Change this if the agency prescribes a format. |
| A-24 | Legacy timestamps (`timestamp without time zone`) are Europe/Berlin local time. | Needed to convert them to `timestamptz`. |

### Performance and operations
| ID | Assumption | Rationale / effect |
|----|-----------|--------------------|
| A-27 | No partitioning. About 6 M inspections after 30 years and about 0.3 M trees are small for PostgreSQL. A map query for 5,000 trees uses the GiST index plus one index probe per tree for the latest vitality, which should be well under 1 s. If it is not, add a trigger-maintained `latest_vitality_class` column on `tree`. | Volumes are in the requirements. **Not yet benchmarked.** |
| A-28 | Offline sync uses optimistic locking. The tablet sends `row_version`, and the server rejects stale updates for manual resolution. New inspections and measures never conflict because they are inserts with client UUIDs. Synced rows are written under the inspector's login (`SET LOCAL app.actor`). | Last-writer-wins would silently lose auditable data. |

### Legacy migration
| ID | Assumption | Rationale / effect |
|----|-----------|--------------------|
| A-19 | Legacy `x`/`y` are EPSG:25832. An easting with the "32" zone prefix is stripped. The migration aborts if coordinates are missing or out of range. | Must be verified on sample trees. If they are Gauß-Krüger, wrap the coordinates in `ST_Transform(..., 25832)` from 31467 in `migration.legacy_point`. |
| A-20 | Legacy data is incomplete: no crown diameter, no defect severity, no priority, no ordering arborist, no felling date or reason. Migrated rows get `is_legacy_import = true`, which relaxes exactly these checks. The order date of legacy measures is set to the inspection date. The felling date is taken from a completed felling measure where one exists. All remaining gaps are written to `migration.reject` for manual follow-up. | No values are invented. |
| A-32 | Legacy free-text species names, defect lists and measure kinds are mapped through curated tables (`migration.species_map`, `defect_map`, `measure_type_map`). Exact matches are pre-filled, and the load refuses to start while anything is unmapped. Legacy inspections without a tree, and measures without an inspection, cannot be attached and are logged as rejects. | Free text "(!)" in the legacy schema. |
| A-33 | Legacy inspector names become inactive `staff` rows without a login. Spelling variants of the same person must be merged by hand. Inspections without a name point to the placeholder "Unbekannt (Altdaten)". | This keeps the mandatory inspector reference. |
