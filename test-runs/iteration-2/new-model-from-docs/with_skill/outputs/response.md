Hi! The first complete draft of the tree cadastre model is in `datamodel/`. I couldn't ask you anything, so every guess I made is written down and marked as unconfirmed. Nothing is released yet. It's a draft (0.1.0) for you to review.

## What's in `datamodel/`

| File | Content |
|---|---|
| `model.yaml` | The main model, independent of any database or format. All schemas are generated from it |
| `review.md` | **Start here.** A readable data dictionary with the diagram, all object types and attributes, the rules, and the open questions |
| `exports/draft/schema.sql` | Generated PostgreSQL/PostGIS DDL (schema `urban_tree_cadastre`) |
| `exports/draft/schema.json` | Generated JSON Schema (draft 2020-12) for all objects in the exchange file |
| `exports/draft/diagram.mmd` | Mermaid class diagram |
| `handwritten/exchange-file.schema.json` | Wrapper schema for the monthly agency file (reporting period, CRS, lists of trees, inspections, measures, species, sites, contractors). It points to `schema.json` |
| `handwritten/example-exchange-file.json` | Sample monthly file with realistic, non-personal values |
| `handwritten/tuning.sql` | Indexes for the map view, rule checks, history triggers, a no-delete guard on inspections, and the open data view |
| `handwritten/legacy-mapping.md` | Column-by-column mapping from `baum`/`kontrolle`/`massnahme` to the new model |
| `sources.md`, `decisions.md`, `open-questions.md`, `glossary.md`, `CHANGELOG.md` | Where each element comes from, 14 decisions, 11 questions, 16 assumptions, and terms (with the legacy German names) |

## The model in brief

- **Tree**: point location in EPSG:25832, species, site, planting year, status (standing/felled), felling date and reason. Felled trees stay in the cadastre. A replacement tree points to the felled tree it replaces, so one felled tree can have several replacements.
- **TreeLocationCorrection**: keeps every earlier position, with when, who and why. This covers the GPS-correction requirement.
- **Inspection**: date, inspector, trunk circumference (cm), crown diameter (m), height (m), vitality class. It contains a list of **InspectionDefect** entries (defect type and severity low/medium/high). Inspections are never physically deleted: a trigger blocks deletes, and every change goes into a history table ("who changed what").
- **Measure**: type, order date, due date, priority, status, completion date, contractor. It always points to its tree and optionally to the inspection it came from.
- **Species** (the city's list of about 900 entries) has an optional GBIF taxon key so the agency can identify species unambiguously. **Site** is a park or street segment. **Contractor**.
- **StaffMember**: the only place inspector names are stored. Inspections refer to staff only by ID. Neither the open data view nor the exchange file contains names.
- **IDs**: every object gets a UUID that the tablet can create, so offline registration works. The old `baum_nr` is kept as an optional `treeNumber`.
- **Performance**: there is a spatial (GiST) index for the map view (about 5,000 trees in a bounding box in under 1 s). About 6 million inspections after 30 years don't need partitioning; a date (BRIN) index is enough.

## Please check these first

1. **Q-001, must be settled before release: vitality scale.** The requirements and the legacy data use classes 1–5 "according to Roloff". But Roloff's published vitality key has only four classes, 0–3. I checked this online in secondary sources. For now I kept 1–5 and assumed 1 = best. Which scale do your inspectors actually use?
2. **Monthly file (Q-006, Q-008):** I assumed:
   - a full snapshot every month (not just changes);
   - the agency checks the file strictly against the schema, so any field it doesn't know is rejected;
   - coordinates stay in EPSG:25832. Standard GeoJSON expects WGS 84, so this needs to be agreed with the agency.
3. **Code lists (Q-003):** for defect types and measure types I only have the examples from the requirements. Felling reasons and measure priorities are my guesses. Can you send me the department's lists? These lists are designed so that you can add values later without a new model version.
4. **Tree numbers (Q-002):** tablets can't assign the next number while offline. I assumed the server assigns `treeNumber` at the evening sync. Is that acceptable?
5. **Sites (Q-004):** is there a street register with segment keys? The legacy data only has free-text street and park names.

All other assumptions are listed in `open-questions.md` and at the top of `review.md`.

## What I checked, and what not

- The model passes the steward tool's validation with no errors. The only warning is that the 20 elements marked "proposed" still need your OK. Until then, the tool refuses to create a release.
- I validated the JSON Schemas and the sample exchange file with `jsonschema`. The sample passes. A wrong vitality class or an extra field such as an inspector name is rejected. For this test I used a simplified local copy of the GeoJSON Point schema.
- The SQL has **not been run against a database**, because no PostgreSQL is available here. Please run `schema.sql` and then `tuning.sql` on a scratch database with PostGIS.
- Migrating the legacy data will need cleanup work. The main points:
  - species names are free text;
  - street and park are free text;
  - defects are a comma-separated list without severity;
  - measures have no tree, order date or priority.

  `handwritten/legacy-mapping.md` lists every case.

Once you've answered the questions, I'll update the model, regenerate the schemas and, if you want, write the migration script and release 0.1.0 or 1.0.0.
