Hi! The first draft of the tree cadastre data model is in `datamodel/`. It's **version 0.1.0, status draft, and not released**. I couldn't ask you anything, so I wrote down every assumption I made. The main ones are listed below so you can check them between meetings.

## What's in `datamodel/`

| File | What it is |
|------|------------|
| `model.yaml` | The main model. It doesn't depend on any one database or format, and all schemas are generated from it |
| `diagram.mmd` | Class diagram (Mermaid) |
| `exports/0.1.0/schema.sql` | PostgreSQL/PostGIS DDL, **generated** from the model |
| `exports/0.1.0/tuning.sql` | Hand-written addition to run after `schema.sql`. It adds defaults, the business rules (CHECK constraints and triggers), the audit trail, a block on deleting inspections, the map index (GiST), sync columns and the open-data view `open_data_tree` |
| `exports/0.1.0/schema.json` | JSON Schema (draft 2020-12) for every object type, **generated** from the model |
| `exports/0.1.0/exchange-file.schema.json` | Wrapper for the monthly file to the agency. It holds the delivery details plus lists of species, parks, street segments, contractors, trees, inspections and measures |
| `exports/0.1.0/examples/exchange-file.example.json` | A realistic example exchange file |
| `decisions.md` | 14 design decisions (D-001…D-014), each with its options and reasons |
| `open-questions.md` | **8 open questions and 18 working assumptions: please read this one** |
| `sources.md`, `glossary.md` | Register of your two documents, and a glossary of terms (including the German legacy names) |
| `legacy-mapping.md` | Column-by-column mapping from `baum`/`kontrolle`/`massnahme` to the new tables, including the gaps in the legacy data |
| `CHANGELOG.md` | Entry for 0.1.0 |

## The model at a glance

- **Tree**: location (point in ETRS89/UTM 32N, EPSG:25832), planting year, status (standing/felled), felling date and reason. Each tree has one **Species** and one **Site**, which is either a **Park** or a **StreetSegment**.
  - Felled trees stay in the cadastre.
  - **CompensationPlanting** links new trees to the felled trees they replace.
  - **LocationCorrection** keeps the previous point and when it was corrected. A trigger creates one automatically whenever a location changes.
- **Inspection**: date, inspector, trunk circumference (cm), crown diameter (m), height (m) and vitality 1–5. Each inspection can have any number of **defects**, each with a type and severity.
  - Inspections can never be deleted.
  - Every change to them is recorded with who made it and when.
- **Measure**: ordered from an inspection. It has a type, order date, due date, priority and status (ordered/done/cancelled), plus a completion date and a **Contractor**.
- **StaffMember** (inspectors and arborists) holds the only personal data. Staff names never go into the open data or the agency file. The agency file only carries a staff id.
- **Lists that change over time** are stored as editable tables, so the department can add entries without a model change. This covers species (about 900), defect types, measure types and felling reasons.
- **The free-text and comma-separated fields in the legacy schema** become proper references and lists in the new model. These are species, street/park, defects, inspector and contractor.

## Key design choices (details in `decisions.md`)

1. **IDs are generated on the tablet (UUIDs)**, because inspectors work offline. The old `baum_nr` is kept as `treeNumber`, and new trees get their number when they sync.
2. **The exchange file uses flat lists that refer to each other by id**, instead of putting inspections and measures inside each tree. A monthly delta often contains a measure that was finished this month for an inspection from an earlier month. The wrapper schema is the only hand-written part, and it only points into the generated schema.
3. **The latest vitality and the last inspection date are stored on each tree** and kept up to date by a trigger. That keeps the map view (about 5,000 trees in under 1 s) and the nightly open-data export fast.
4. **History**: every table has an audit trail (who changed what, and when). There's no full version history, except for location corrections.

## Please check these first (they block a release)

- **Q-002 Vitality scale:** the requirements say "1–5 according to the Roloff scale", but the Roloff scale has four classes, 0–3. For now I've kept 1–5, as in the legacy database. Which scale do you actually use?
- **Q-006 Agency format:** does the agency prescribe a format? Which coordinate system do they want? Standard GeoJSON expects WGS84 coordinates; the draft sends EPSG:25832. Should the file be a monthly delta (the current assumption) or a full snapshot?
- **Q-007 Data protection:** may the pseudonymous inspector id go to the agency at all? How long do we keep staff records?
- **Q-003, Q-005, Q-008 Legacy migration:**
  - Q-003: how do we handle free-text species names that don't match the species list?
  - Q-005: measures without an inspection exist in the legacy data. Should those be allowed?
  - Q-008: which coordinate system are `x`/`y` in? Some trees may have both a street and a park filled in.
- **Codes I invented, since the requirements don't give any:** measure priority (immediate/high/normal/low) and felling reasons. I also assumed one new tree can replace several felled trees.
- **Q-001:** the namespace is a placeholder (`https://data.example-city.org/...`).

The model also contains 14 small additions you didn't ask for, such as remarks, `commonName` and an order date. They are marked `proposed` and listed at the end of `open-questions.md`. Keep or drop them as you like.

## What I checked and what I couldn't

- ✅ The model passes the skill's validator (0 errors). The only warning is about the `proposed` elements above.
- ✅ Both JSON Schemas are themselves valid. The example exchange file passes them. Test files with an unknown field, a vitality of 6 or an unknown priority were correctly rejected. The GeoJSON schemas were checked against local copies, because they're referenced online.
- ❌ **I haven't run `schema.sql` and `tuning.sql` against a database**, because no PostgreSQL was available. Please run them once on a scratch PostGIS database before anyone builds on them.

## Next steps

Once you've gone through `open-questions.md`, I'll update the model and regenerate the schemas. After that we can release it as 1.0.0 for the app team and the agency.
