# Open questions and assumptions

## Questions

- **Q-001 (blocking before release)** Vitality scale: S1/S2 use classes 1–5 "according to Roloff", but Roloff's published key has 4 classes (0–3). Does the city use its own 5-level scale (and is 1 = best?), or should we switch to Roloff 0–3 and map legacy values? — owner: arborist team
- **Q-002** Is `baum_nr` physically on the trees (tags), and must new trees get a number immediately (offline), or is server assignment at sync acceptable?
- **Q-003** Please provide the full defect list and measure-type list (and the distinct legacy values of `massnahme.art` and `kontrolle.maengel`) so the code lists can be completed.
- **Q-004** Is there a street register with segment keys (which one)? Do parks have official boundaries we can reference?
- **Q-005** Can one new tree compensate for several felled trees? Is a required number of compensation trees per felled tree (tree protection bylaw) to be tracked?
- **Q-006** Exchange file: full snapshot every month or only changes since the last file? Include felled trees and logically deleted records?
- **Q-007** Retention for staff data and audit trails; may pseudonymous inspector UUIDs be passed to the agency?
- **Q-008** Which CRS/format does the agency expect (EPSG:25832 vs. WGS 84 GeoJSON), and does it validate strictly against our schema?
- **Q-009** Offline sync conflicts: what wins if the office and a tablet change the same tree on the same day?
- **Q-010** Official namespace URI for the model / schema `$id` (placeholder `https://example.org/models/urban-tree-cadastre`).
- **Q-011** "Latest vitality" for open data: the latest inspection that has a vitality class, or the latest inspection at all?

## Assumptions

- A-001 Documentation in English only; German can be added (confirmed: no)
- A-002 Tree location is a point (trunk position) in EPSG:25832 (confirmed: no)
- A-003 Every tree belongs to exactly one site (park or street segment); legacy rows with neither or both need cleaning (confirmed: no)
- A-004 Trunk circumference, crown diameter and height are optional per inspection; vitality is mandatory for new inspections (C-005) (confirmed: no)
- A-005 Vitality 1 = best, 5 = worst (confirmed: no — see Q-001)
- A-006 Trunk circumference measured at 1 m height (confirmed: no)
- A-007 Felling reasons: disease/decay, dead, traffic safety, storm damage, construction, other (confirmed: no)
- A-008 Measure priority: immediate / high / normal / low (confirmed: no)
- A-009 Measures can be cancelled (status `cancelled`) instead of deleted (confirmed: no)
- A-010 Measures kept 30 years like inspections; trees kept indefinitely (confirmed: no)
- A-011 Exchange file contains staff UUIDs but no names; open data contains no staff reference (confirmed: no)
- A-012 The regional agency validates strictly → closed JSON Schema (confirmed: no)
- A-013 Tree status only standing/felled; a dead tree still standing is `standing` with low vitality; storm-thrown trees are `felled` with reason `stormDamage` (confirmed: no)
- A-014 "Who changed what" via generic audit history tables for all entity classes; no business-level versioning (confirmed: no)
- A-015 Legacy felled trees have no felling date/reason, so C-001 applies only to new data (scope new) (confirmed: no)
- A-016 Offline sync is an application concern; the model only provides client-generated UUIDs and audit timestamps (confirmed: no — see Q-009)
