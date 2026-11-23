Hi,

The first draft of the tree cadastre data model is in `datamodel/`. The JSON Schema for the agency file has been tested. The SQL has not been run yet, because no PostgreSQL/PostGIS database was available here. I only reviewed it by hand.

Please start with **`datamodel/ASSUMPTIONS.md`**. It lists every assumption I made (A-01 to A-33). At the top are the 7 that change the model the most if I got them wrong.

## What's in the folder

- **The PostgreSQL/PostGIS schema** (`sql/01`–`03`):
  - Tables for trees, inspections, defects, measures, felling, replacement plantings and the code lists.
  - Rules in the database itself:
    - Inspections, trees and measures can't be deleted. Trees are marked felled and measures cancelled instead.
    - An audit log records who changed what.
    - Every location correction keeps the previous position and when it changed.
    - Data entered offline on tablets can be synced in the evening without conflicts.
  - A map view and indexes for the "5,000 trees in under 1 s" requirement.
  - The nightly open data set (`opendata.tree`), which contains no personal data.
  - A database function that builds the monthly agency file.
- **The JSON Schema for the monthly agency file**, plus an example file (`json/`). Inspectors appear only as pseudonyms, never by name.
- **Starting code lists** (`sql/04`). Only the defects and measure types named in the requirements are confirmed. The rest are my proposals.
- **A migration from the legacy tables** (`sql/05`, explained in `legacy_mapping.md`):
  - Free-text species, defects and measure types go through mapping tables.
  - The migration won't start until everything is mapped.
  - Problem rows go to a reject table.
  - Missing legacy data stays empty and the row is flagged as legacy; nothing is made up.
- **`model.md`**: an entity-relationship diagram, the design decisions, and a table showing where each requirement is covered.

## Please check these first

1. **Vitality scale.** The requirements say "1–5 according to Roloff", but the Roloff scale only goes from 0 to 3. I used 1–5 for now.
2. **What the agency receives.** I assumed a monthly file with only what was added or changed that month. I also assumed coordinates stay in the city's own system (ETRS89 / UTM 32N), so the file is not standard GeoJSON. Does the agency prescribe a format?
3. **Inspectors in the agency file.** I send a stable pseudonym instead of the name. Should the agency get even that?
4. **Legacy coordinates.** I assumed the old `x`/`y` values already use ETRS89 / UTM 32N. If they use the older Gauß-Krüger system, the migration needs a one-line conversion.
5. **Park or street.** I assumed every tree belongs to exactly one park or one street segment. I also assumed the park and street geometries come from the city GIS.
6. **Replacement plantings.** I added a field for how many replacement trees a felling requires, so open obligations can be listed. Where does that number come from?
7. **Official lists.** I need the department's lists of defects, measure types, priorities and felling reasons.

## How it was checked

- **JSON Schema:** the example file validates. 13 deliberately broken variants are all rejected, for example:
  - a living tree with felling data
  - an inspector's name instead of a pseudonym
  - a missing defect severity
  - a finished measure without a contractor
- **SQL:** not run, only reviewed by hand. Before relying on it, it needs three things on a PostgreSQL 15+/PostGIS 3.3+ test database:
  - run all the scripts
  - check the generated agency file against the schema
  - time the map query with realistic data volumes
