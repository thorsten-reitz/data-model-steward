# Open questions and working assumptions

Draft 0.1.0 was produced on 2026-11-23 without being able to ask the parks department.
**Questions (Q)** need an answer; **assumptions (A)** are what the draft currently does — please confirm or correct.
"Blocks release" = must be settled before version 1.0.0 is handed to the agency or the app team.

## Open questions

| ID | Question | Current working answer | Blocks release | Sources |
|----|----------|------------------------|----------------|---------|
| Q-001 | What is the official base URI / namespace for the model and the JSON Schema `$id`? | Placeholder `https://data.example-city.org/models/tree-cadastre` (A-001) | yes (exchange) | — |
| Q-002 | **Vitality scale conflict:** S1 says "vitality class (1–5) according to the Roloff scale", but Roloff's scale has four classes 0–3 (exploration, degeneration, stagnation, resignation). Legacy stores 1–5. Which scale is really used — a 5-step city scale, Roloff 0–3, or Roloff with intermediate steps? | Integer 1–5 as in S1 and S2; no code labels | yes | S1 UC2, S2 `kontrolle.vitalitaet` |
| Q-003 | Legacy `baum.art_lat` is free text. How do we handle names that don't match the species list (typos, synonyms, "unknown")? Is species mandatory for every tree? | Mandatory; migration maps names to the list, unmatched names go to a manual clean-up list; possibly a list entry "unknown species" | yes (migration) | S1 UC1, S2 |
| Q-004 | Full lists of defect types and measure types? Who may add values, and must the agency be told about new values? | Only the examples from S1 loaded; both lists extensible, maintained by the department | no (data, not model) | S1 UC2, UC3 |
| Q-005 | Can measures exist **without** an inspection (e.g. emergency after a storm)? Legacy `massnahme.kontrolle_id` is nullable. | No — every measure stems from an inspection (S1 UC3); legacy measures without inspection need a migration rule | yes (migration) | S1 UC3, S2 |
| Q-006 | Exchange file with the agency: does the agency prescribe a format/standard? Which CRS (EPSG:25832 or WGS84 as required by RFC 7946 GeoJSON)? Delta per month or full snapshot? Do they want location corrections and compensation links? | Own JSON format, delta, coordinates in EPSG:25832, all objects incl. corrections and compensation links (A-004) | yes (exchange) | S1 UC5 |
| Q-007 | Personal data: may the **pseudonymous** staff id of inspectors/orderers be sent to the agency? How long must staff data be kept after a person leaves (inspections are kept 30 years and reference the inspector)? | Id is sent, names are not; staff records are logically deleted but kept as long as inspections reference them | yes (data protection) | S1 "Other" |
| Q-008 | Legacy data: in which CRS are `baum.x`/`baum.y` (S2 says nothing)? Can a legacy tree have both `strasse` and `park` filled — and which wins? | x/y already EPSG:25832; if both filled, park wins and the street is noted for clean-up (A-014) | yes (migration) | S2 |

## Working assumptions

| ID | Assumption | Where it shows in the model |
|----|------------|-----------------------------|
| A-001 | Placeholder namespace and prefix `tc` | `model.namespace`, JSON `$id` |
| A-002 | Canonical names in English; German legacy terms only in glossary | everywhere (D-002) |
| A-003 | Tree number (`baum_nr`) is still used by staff (e.g. on tree tags); new numbers are assigned by the server at sync, so `treeNumber` is optional | `Tree.treeNumber` |
| A-004 | The monthly exchange file contains everything created or changed in that calendar month plus the species, sites and contractors those objects reference | `exchange-file.schema.json` |
| A-005 | Staff names never leave the system (not in open data, not in the exchange file) | `StaffMember` excluded from envelope and open data view |
| A-006 | Trunk circumference, crown diameter and height are optional per inspection (not always measured); inspection date, inspector and vitality are mandatory | `Inspection` multiplicities |
| A-007 | Trunk circumference is measured at 1.0 m above ground | `Inspection.trunkCircumference` description |
| A-008 | The ordering arborist is recorded but optional, because legacy measures don't have one | `MeasureOrderedBy` 0..1 |
| A-009 | Parks and street segments are maintained in the cadastre itself (~5,000 records, guessed); their geometry is optional and its changes are not audited; `externalCode` links to the city GIS/street register if one exists | `Site`, `Park`, `StreetSegment` |
| A-010 | Measures are kept as long as inspections (30 years) | `Measure.nfr.retention` |
| A-011 | Compensation planting is many-to-many: a felled tree can be replaced by several new trees (S1) **and** one new tree can compensate several felled trees (assumed) | `CompensationPlanting` |
| A-012 | Felling reason codes: disease, trafficSafety, stormDamage, dead, construction, other (invented) | `FellingReason` |
| A-013 | Measure priority codes: immediate, high, normal, low (invented; S1 gives none) | `MeasurePriority` |
| A-014 | Every tree belongs to exactly one site (park **or** street segment) | `TreeSite` multiplicity 1 |
| A-015 | A done measure may have no contractor (work by the in-house team) | `MeasureContractor` 0..1 |
| A-016 | No "as known on date X" reporting is needed beyond location corrections; the audit trail suffices | `history.mode: audit` (D-014) |
| A-017 | Inspectors and arborists are department staff (not external experts) | `StaffMember` |
| A-018 | Felled trees keep their last inspections; no new inspections/measures after the felling date | C-004, C-007 |

## Elements still marked `status: proposed` in model.yaml
FellingReason, MeasurePriority, DefectFinding.remark, Species.commonName, Site.externalCode, Park.area,
StreetSegment.axis, Tree.fellingRemark, LocationCorrection.reason, Inspection.remark, Measure.orderDate,
Measure.description, StaffMember.active, MeasureOrderedBy — additions not explicitly requested by S1/S2.
Confirm or drop them before release (the validator blocks a release while any remain).
