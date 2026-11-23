Hi! The first draft of the tree cadastre data model is in `datamodel/`. It includes the PostgreSQL/PostGIS schema, the JSON Schema for the monthly agency file, and a migration script from the legacy tables. The SQL has not been run on a real database yet; it was only checked for correct syntax.

**Five assumptions to check first** (details and the full list of A-01 to A-31 are in `datamodel/ASSUMPTIONS.md`):

1. **Vitality scale (A-10).** The requirements say "1–5 according to Roloff", but the published Roloff scale has 4 classes (0–3). I kept 1–5, because the legacy data uses it too. The classes are in a lookup table, so the scale can change without a schema change. The class labels are placeholders.
2. **What goes into the agency file (A-24).** Each month the file contains every tree, plus the inspections and measures created or changed that month. If the agency has its own format, we should use theirs instead.
3. **Coordinates in the agency file (A-29).** Points are easting/northing in EPSG:25832. I did not use GeoJSON, because GeoJSON requires WGS84.
4. **Park or street (A-07).** Every tree belongs to exactly one park or one street segment, and the database enforces this.
5. **Offline tablets (A-17).** Tablets create the record IDs themselves. If a tree or measure changed on the server since the tablet last synced, the server rejects the tablet's change and the app has to resolve the conflict.

**What's in the folder**
- **`README.md`**: a diagram of the tables, a table showing where each requirement is covered, how each legacy field maps to the new model, and design notes.
- **`ASSUMPTIONS.md`**: all assumptions, each marked with how much would change if it's wrong, plus 8 open questions.
- **`sql/01_schema.sql`**: the tables, including:
  - species, defect, measure-type and felling-reason lists the department can extend
  - parks, street segments, staff and contractors
  - trees, location history, replacement plantings, inspections with defects, and measures
  - an audit log and a log of exports
- **`sql/02_audit_and_rules.sql`**:
  - **Change tracking:** who changed what, with old and new values.
  - **Deletion protection:** trees, inspections and measures can never be deleted.
  - **Location history:** every location correction automatically keeps the previous point.
  - **Personal data:** database roles keep it restricted.
- **`sql/03_views.sql`**:
  - the nightly open-data view (standing trees only, no names)
  - lists of overdue inspections and missing replacement plantings
  - `export_agency_exchange()`, which produces the monthly agency file
- **`sql/04_seed_codelists.sql`**: starter code lists. These are placeholders and need to be replaced with the department's official lists.
- **`sql/90_migrate_legacy.sql`**: migrates `baum`/`kontrolle`/`massnahme`.
  - Step 1 builds tables matching legacy free text (species, defects, measure types, names) to the new lists. Please review these before running step 2.
  - Step 2 loads the data. Anything it can't migrate cleanly is written to `legacy.migration_issue`, and it ends with a row-count comparison.
- **`json-schema/tree-exchange.schema.json`**, with an example file in `json-schema/examples/`.
- **`tests/validate_exchange_schema.py`**: checks the example file and 11 deliberately broken versions.

**How requirements are covered**
- **Inspections:** they can't be deleted, and the audit log shows who changed what.
- **Felled trees:** they stay in the database as `felled`, with date and reason. Replacement trees are linked to them.
- **Personal data:** inspector names never appear in open data. The agency file contains only a pseudonymous inspector code (A-18); please confirm the agency may receive it.
- **Map view:** with spatial indexes, loading about 5,000 trees should be well under a second. This hasn't been measured with real data yet.
- **Data volume:** 30 years of inspections is about 6 million rows, which doesn't need any table partitioning.

**Legacy data issues the migration handles**
- **Species:** the botanical name is free text. It is matched to the species list, and the original text is kept.
- **Defects:** they are stored as a comma-separated list without severity, so migrated defects have no severity.
- **Felled trees:** they have no felling date or reason. The date is taken from a completed felling measure where one exists; the rest are listed for you to complete.
- **Measures:** they have no order date or priority. The migration uses the inspection date and priority "normal".
- **Coordinates:** I assumed legacy x/y are already EPSG:25832 (A-02). Please check a few known trees before migrating.

**What was checked**
- The JSON Schema is valid. The example file passes, and all 11 broken versions are rejected.
- All SQL files, including the trigger and function code, pass the PostgreSQL parser.
- Not yet done:
  - installing the scripts on a PostGIS instance
  - running the migration on the 2026-09-30 dump
  - validating real `export_agency_exchange()` output against the schema
  - timing the map query with real data

These are the next steps once a dev database is available.
