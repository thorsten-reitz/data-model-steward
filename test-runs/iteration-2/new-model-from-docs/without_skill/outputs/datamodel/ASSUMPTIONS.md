# Assumptions and open questions – Urban Tree Cadastre data model v0.1.0

I made these decisions without being able to ask anyone. Each one has an ID that
the SQL and JSON Schema refer to (`[A-nn]`). Please confirm or correct them.
**Impact** says how much has to change if the assumption is wrong.

Legend: **H** = schema/structure change, **M** = constraint or code-list change, **L** = cosmetic.

## Items to check first

These either contradict something in the source documents or have the biggest effect
on the design.

| ID | Topic | What I assumed | Why it matters | Impact |
|----|-------|----------------|----------------|--------|
| A-10 | **Vitality scale** | The requirements say "1–5 according to the Roloff scale", and the legacy table also uses 1–5. **The published Roloff scale has 4 classes (0–3).** I kept 1–5 because both sources agree, and put the classes in a lookup table (`vitality_class`) so the scale can change without DDL. The labels in `04_seed_codelists.sql` are made up. | If the agency expects real Roloff 0–3, the exchange file and the legacy values need a mapping. | M |
| A-24 | **Exchange file scope** | Monthly file = **full snapshot of all trees** plus **inspections and measures created or changed in the month** (delta, upsert by UUID). | The regional agency's actual spec is unknown. A pure delta or a full dump of everything would change the export function and the root of the JSON Schema. | H |
| A-29 | **Coordinates in the exchange file** | Plain `{easting, northing}` in EPSG:25832, declared once in `header.crs`. I did **not** use GeoJSON, because RFC 7946 requires WGS84. | If the agency wants GeoJSON (WGS84) or GML, the `location` definition changes. | M |
| A-07 | **Park or street segment** | Every tree belongs to **exactly one** park **or** one street segment (DB CHECK). Legacy trees with both use the park. Trees with neither go to a placeholder segment `LEG-UNASSIGNED`. | Trees on a street *inside* a park, or squares that are neither, would need a different rule. | M |
| A-17 | **Offline sync** | Tablets generate the UUID primary keys (`tree_id`, `inspection_id`, `measure_id`). Conflicts on trees and measures use optimistic locking through `row_version`: a stale update is rejected and the app has to resolve it. Inspections are effectively insert-only, so they rarely conflict. | A different sync product, such as a CouchDB or PowerSync-style replication layer, might need extra columns (tombstones, vector clocks). | M |
| A-18 | **Personal data** | Inspector and arborist names live only in `staff.full_name`. Exports use a pseudonymous `staff_code`. The **open data** export contains no person reference at all. The **agency** file carries only `inspectorCode`. | Confirm the agency may receive the pseudonymous code, or whether it should get nothing. The data protection officer should check this. | L |

## Full list

### General / naming
- **A-01** Tables and columns use English snake_case names in schema `cadastre`. The exchange file uses camelCase. Legacy German names appear only in the migration script.
- **A-19** The application sends the end user per transaction (`SET LOCAL app.user = '<login>'`). The audit log records that name, or the DB role if it is missing. Each person therefore needs a `staff.login_name`.
- **A-20** Every core row has `origin` (`app` | `legacy_migration`). Some NOT NULL rules are relaxed **only** for migrated rows, because the legacy data cannot satisfy them (see A-21 to A-23).

### Trees
- **A-02** Legacy `x`/`y` (numeric(10,2)) are already EPSG:25832 metres. *Please verify with a few known trees.* If they are Gauss-Krüger (EPSG:31466/31467), the migration needs `ST_Transform`.
- **A-03** `tree_number` (the legacy `baum_nr`) stays as the human-readable, public, stable tree id (tag number). New trees get numbers from a sequence starting at 1,000,000, so they cannot collide with legacy numbers. Offline tablets do not need a number: the server assigns it on sync, and the UUID is the technical key.
- **A-04** The planting year is optional and must lie between 1600 and 2100. Approximate years ("around 1950") are stored as a plain year, with no accuracy flag.
- **A-05** The species list gets a stable short `species_code`, used in exports instead of the botanical name alone. Renamed species are handled through `is_active` plus `replaced_by_id`. Arborists maintain the list directly in the DB/app; there is no approval workflow.
- **A-06** Parks and street segments are master data imported from the city GIS or street register. The tables are minimal (code, name, geometry). The migration creates placeholder entries (`LEG-P-nnnn`, `LEG-S-nnnn`) for legacy names it cannot match.
- **A-08** Tree status is `standing` | `felled` | `void`. `void` marks a record created in error (for example a duplicate), because trees can never be deleted. Void trees are excluded from open data but included in the agency snapshot so the agency can withdraw them.
- **A-15** Completing a measure of a felling type (`measure_type.is_felling`) does **not** automatically fell the tree. The app performs UC4 explicitly in the same transaction: it sets status, date, reason and `felling_measure_id`. This avoids a trigger having to guess the felling reason.
- **A-16** Compensation planting is modelled **many-to-many** (`tree_replacement`): one felled tree can be replaced by several trees, and one new tree could compensate several felled ones. `tree.compensation_required` holds the number of replacements required, if a permit sets one. `v_compensation_open` lists felled trees still missing replacements. If nothing is set, it assumes 1.
- **Location corrections:** every change of `tree.location` automatically writes the previous point, its validity period and the person who changed it to `tree_location_history`. The app can supply a reason with `SET LOCAL app.correction_reason`.

### Inspections
- **A-09** One defect type appears at most once per inspection, with one severity. Defect rows may be deleted to correct a mistake, and the deletion is audited. Inspections themselves cannot be deleted.
- **A-11** Trunk circumference is measured at 1.0 m height, as an integer in cm. Crown diameter and height use 0.1 m resolution. The plausibility ranges (circumference 1–2000 cm, crown 0.1–60 m, height 0.1–80 m) are my guesses.
- **A-12** Vitality class is mandatory for new inspections. Circumference, crown and height are optional, because some trees cannot be measured every year.
- **A-26** "At least once a year" means the latest inspection is less than 365 days old (`v_inspection_overdue`). It does not mean "once per calendar year".
- "Inspections must never be deleted; auditors need to see who changed what": this is enforced by a delete-blocking trigger (which also covers the table owner and TRUNCATE), a missing DELETE privilege, and a generic `audit_log` holding old and new values as JSONB for trees, inspections, defects, measures, replacement links and code lists.

### Measures
- **A-13** Priority values are `immediate`, `high`, `normal` and `low`. The department may already use a different scale, such as the "Dringlichkeit" levels of the FLL guidelines.
- **A-14** Measure status is `ordered` → `done` | `cancelled`. Cancelling needs a reason, and measures are never deleted. Requirement UC3 does not mention cancellation.
- A measure always comes from exactly one inspection (UC3). `measure.tree_id` repeats the tree but is kept consistent with a composite foreign key to `inspection(inspection_id, tree_id)`.
- The person who orders a measure (`ordered_by_id`, an arborist) is recorded. UC3 implies this but does not say it explicitly.

### Legacy migration
- **A-21** Legacy felled trees have no felling date or reason. The migration takes the date from the latest completed felling measure, if there is one, and uses reason `UNKNOWN_LEGACY`. Felled trees still without a date are listed for manual completion. Legacy measures have no order date, so the migration uses the inspection date.
- **A-22** Legacy defects (the comma-separated `maengel`) have no severity, so `severity` is NULL for migrated defects only. Tokens that cannot be mapped become `OTHER`, and the original text is kept in `inspection.legacy_defects_text`.
- **A-23** Legacy measures marked done may have no contractor. That is allowed for migrated rows only. Legacy measures without a priority get `normal`.
- Legacy inspector names become `staff` rows (codes `LEG-nnnn`, inactive). Matching them to current staff is a manual review step.
- Legacy `geaendert_am`/`geaendert_von` (last change only) becomes one baseline audit entry per tree. Earlier change history does not exist in the legacy system.

### Exports and performance
- **A-25** Volumes are small for PostgreSQL: about 6 million inspections after 30 years and about 750,000 measures. **No partitioning is needed.** A GiST index on `tree.location` plus a `(tree_id, inspection_date DESC)` index make a bounding-box query for 5,000 trees with their latest vitality fast (expected well under 100 ms; still to be measured with real data). If not, add a cached `latest_vitality_class` column on `tree`, maintained by a trigger.
- **A-27** The open data id is the public `tree_number`, not the internal UUID. Open data contains id, species (code, botanical name, German common name), planting year, coordinates in both EPSG:25832 and WGS84, and the latest vitality class. It is published as the materialized view `mv_open_data_tree`, refreshed nightly. The file format (CSV, GeoJSON, WFS) is left to the portal team.
- **A-28** All code-list values in `04_seed_codelists.sql` (defects, measure types, felling reasons, vitality labels) are placeholders. The department's official lists must replace them before go-live.
- **A-30** Data is kept for 30 years, as the requirements say. There is no automatic purge. GDPR retention for staff names (for example after an inspector leaves) is not modelled yet; this needs a decision.
- **A-31** Contractor company names are not personal data and appear in the agency file. Sole traders whose company name is a person's name would be an exception. Please check.
- The agency file carries `municipalityCode` (8-digit German AGS). I assumed the agency identifies the sender this way.

## Open questions (answers would change the model)

1. Does the agency publish its own exchange format, code lists or schema? If so, we should map to it instead of defining our own (A-24, A-29).
2. Vitality scale: is it 1–5 or Roloff 0–3, and what are the official labels (A-10)?
3. Can a tree belong to both a park and a street segment, or to neither (A-07)?
4. Should the open data export and the agency file include trees felled in the last period, or only standing trees? Currently open data has standing trees only, and the agency file has all trees.
5. Which offline/sync technology will the tablet app use (A-17)?
6. Do measures need cost, an order number or invoice references (contract management)? These are not modelled.
7. Should the species list carry more attributes, such as the GALK street-tree list rating or native/non-native status?
8. Are there other tree attributes that should be recorded: protected status (tree protection ordinance), owner (city or private), or tree group/stand?
