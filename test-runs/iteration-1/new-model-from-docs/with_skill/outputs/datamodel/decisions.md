# Decision log — Tree Cadastre model

All decisions below were taken on 2026-11-23 **without user confirmation** (user unavailable, asked for a
complete draft with documented assumptions). Status "proposed" = to be confirmed by the parks department.
Related assumptions/questions: `open-questions.md`.

| ID | Topic | Status |
|----|-------|--------|
| D-001 | Purposes and export targets | proposed |
| D-002 | Naming language and conventions | proposed |
| D-003 | Identity: UUIDs generated on the tablet, tree number kept | proposed |
| D-004 | Location corrections as explicit `LocationCorrection` records | proposed |
| D-005 | Felling is a lifecycle state, not a deletion | proposed |
| D-006 | Species as reference class; defect/measure types as extensible code lists; defects as datatype | proposed |
| D-007 | Explicit measure status incl. `cancelled` | proposed |
| D-008 | `Site` hierarchy (Park / StreetSegment) and `StaffMember` | proposed |
| D-009 | Derived latest vitality stored redundantly in the database | proposed |
| D-010 | Exchange file: flat lists + hand-written envelope | proposed |
| D-011 | JSON Schema: closed content, GeoJSON geometry in EPSG:25832 | proposed |
| D-012 | Hand-written `tuning.sql` next to generated DDL | proposed |
| D-013 | `modified_at` columns for offline sync and deltas | proposed |
| D-014 | Data history: audit trail for all classes, no versioning | proposed |

---

### D-001 — Purposes and export targets
- **Context:** S1 asks for an operational database used daily, a nightly open data export and a monthly exchange file to the regional agency; the user named PostgreSQL/PostGIS and JSON Schema.
- **Options:** (a) persistence + exchange, targets postgres + jsonschema; (b) additionally XSD; (c) a separate schema for the open data feed.
- **Choice:** (a). The open data feed is a database view (`open_data_tree` in `tuning.sql`), not a separate model — it is a projection of `Tree`. No XSD.
- **Rationale:** matches the user's stated targets; adding XSD later is a non-breaking regeneration.

### D-002 — Naming language and conventions
- **Choice:** English canonical names (UpperCamelCase classes, lowerCamelCase attributes, lowerCamelCase enum codes); snake_case in PostgreSQL (generated). Legacy German names are mapped in `glossary.md` and `legacy-mapping.md`.
- **Rationale:** the model is exchanged with an external agency and published as open data; S1 is written in English. (A-002)

### D-003 — Identity
- **Context:** inspectors register trees and inspections **offline** on tablets and sync in the evening (S1). Legacy `baum.baum_nr` is an integer PK, probably printed on tree tags.
- **Options:** (a) server sequence as PK; (b) UUID generated on the client as PK, legacy/visible number as separate attribute; (c) natural key.
- **Choice:** (b) for every class: attribute `id` (UUID, `external: true` for objects exchanged with the agency). `Tree.treeNumber` keeps `baum_nr` for migrated trees and is assigned by the server at sync for new trees (therefore `0..1`).
- **Rationale:** offline clients cannot draw from a server sequence without conflicts; UUIDs are stable across the app, the exchange file and open data. (A-003)

### D-004 — Location corrections
- **Context:** S1 "Other": location can be corrected later; previous location and correction time must be known.
- **Options:** (a) bitemporal `Tree` (valid + transaction time); (b) explicit composition `Tree` 1 → 0..* `LocationCorrection(previousLocation, correctedLocation, correctedAt, reason)`; (c) rely on the generic audit trail only.
- **Choice:** (b), filled automatically by a trigger whenever `tree.location` changes (C-010, `tuning.sql`).
- **Rationale:** the requirement concerns one attribute; bitemporal modelling of the whole tree would burden every query, and the generic audit trail (jsonb) is not convenient for business queries or the exchange file. (b) is also exchangeable as nested data.
- **Revisit if:** more attributes need "as known on date X" reporting → switch Tree to `bitemporal` (major change).

### D-005 — Felling is a lifecycle state
- **Context:** S1 UC4: felled trees stay in the cadastre with felling date and reason. Legacy: `gefaellt char(1)` 'J'/'N'.
- **Choice:** `Tree.status` (closed enum `standing | felled`) + `fellingDate`, `fellingReason` (extensible code list), rule C-001. Independently, `deletion: logical` (`deleted_at`) exists only to retire **erroneous** records (e.g. a duplicate registration) — it is not used for felling.

### D-006 — Code lists and species
- **Species:** ~900 entries, extended by the arborist team a few times a year (S1 UC1) → modelled as a **class** `Species` (reference data with its own identity and attributes such as `commonName`) rather than an enumeration. New species are data, not model changes. Replaces the free-text `art_lat` (S2).
- **DefectType, MeasureType, FellingReason:** `extensible: true` → lookup tables in PostgreSQL, open string with known values in JSON Schema. S1 calls the defect list "fixed … maintained by the department"; we read "maintained" as "the department may add values", which should not require a model release. (Q-004)
- **DefectSeverity, MeasurePriority, MeasureStatus, TreeStatus:** closed enums (small, stable, consumers may rely on them).
- **DefectFinding** is a **datatype** (no identity, multi-valued on `Inspection`) replacing the comma-separated `kontrolle.maengel`; becomes child table `inspection_defects`.

### D-007 — Measure status
- **Choice:** explicit `MeasureStatus {ordered, done, cancelled}` with rule C-006 (`done` ⇔ `completionDate`). `cancelled` is an addition to S1 (e.g. a pruning order becomes obsolete when the tree is felled).

### D-008 — Sites and staff
- **Site:** S1 UC1 "the park or street segment it belongs to"; S2 has free-text `strasse` and `park`. Modelled as abstract `Site` with subclasses `Park` and `StreetSegment` (joined tables in PostgreSQL, `allOf` in JSON), each tree referencing exactly one site. (A-009, A-014, Q-008)
- **StaffMember:** inspectors and arborists are one class (personal data isolated in one table) referenced by `Inspection.inspector` and `Measure.orderedBy`. Replaces free-text `kontrolleur`.
- **Contractor:** class replacing free-text `massnahme.firma`.

### D-009 — Derived latest vitality
- `Tree.currentVitality` and `Tree.lastInspectionDate` are `derived: true` in the model (readOnly in JSON). In PostgreSQL they are stored as columns, maintained by trigger on `inspection` (`tuning.sql`), because the map view (5,000 trees < 1 s) and the nightly open data export need them without a per-tree subquery over 6 M inspections.

### D-010 — Exchange file structure
- **Context:** monthly file with trees, inspections and measures (S1 UC5); dmtool's JSON Schema export produces one `$def` per class and nests only compositions.
- **Options:** (a) nest inspections and measures inside trees (composition); (b) flat lists with id references inside an envelope.
- **Choice:** (b). `Inspection → Tree` and `Measure → Inspection` are **references**, not compositions. The envelope `exchange-file.schema.json` is **hand-written** and only `$ref`s the generated `schema.json` of the same version; it adds delivery metadata (`deliveryId`, `reportingPeriod`, `crs`, `schemaVersion`) and lists `species`, `parks`, `streetSegments`, `contractors`, `trees`, `inspections`, `measures`. `StaffMember` is intentionally not listed.
- **Rationale:** a monthly delta contains measures completed this month for inspections of earlier months; nesting would force re-sending old inspections. Flat lists also suit the database.
- **Maintenance rule:** when the model version changes, copy the envelope to the new `exports/<version>/`, update `$id` and `schemaVersion`, and add arrays for new top-level classes. Recorded in `model.exportOptions`.

### D-011 — JSON Schema options
- **Closed content** (`unevaluatedProperties: false`), as recorded in `model.exportOptions.jsonschema.closed`: catches typos and accidental personal data in the file. Consequence: adding optional properties later is a "risk" change for the agency's validator; each file states `schemaVersion` so they can validate against the matching schema.
- **Geometry:** GeoJSON structure (`{"type":"Point","coordinates":[x,y]}`) but with coordinates in **EPSG:25832**, declared once in the envelope (`crs`). RFC 7946 GeoJSON prescribes WGS84 — needs the agency's agreement (Q-006).

### D-012 — `tuning.sql`
- Generated `schema.sql` is never edited. Everything the generator cannot express lives in the hand-written `exports/<version>/tuning.sql`: column defaults, CHECK constraints and triggers for C-001…C-011, the generic audit trigger, the ban on deleting inspections, GiST/BRIN/partial indexes for the NFRs, sync columns, and the open data view.

### D-013 — Sync / delta support
- `modified_at timestamptz` (+ index, touch trigger) on all main tables, added in `tuning.sql` rather than the neutral model, because it is a technical column serving tablet sync and the monthly delta, not business content.

### D-014 — Data history
- All classes `history.mode: audit` (who changed what, when; full row snapshot in `<table>_history`, filled by `audit_row()`). S1 requires it explicitly for inspections ("auditors need to see who changed what"); applied to all classes for uniformity (cheap at these volumes).
- No `versioned`/`bitemporal` mode: no requirement to query past states except the location (D-004). (A-016)
- Inspections: no deletion at all (no `deletion` setting; delete blocked by trigger, C-003). Other classes: logical deletion for erroneous records.
