# Glossary

| Term (model) | Definition | Synonyms / legacy (S2, German) | Not used |
|--------------|-----------|--------------------------------|----------|
| Tree | Individual street or park tree recorded in the cadastre, standing or felled | Baum (`baum`) | "asset" |
| Tree number | Human-readable number of a tree | Baumnummer (`baum_nr`) | — |
| Species | Taxon from the city's species list, identified by botanical name | Art, botanischer Name (`art_lat`) | "type" (ambiguous) |
| Planting year | Year the tree was planted | Pflanzjahr (`pflanzjahr`) | planting date |
| Site | Park or street segment a tree belongs to | Standort (`park`, `strasse`) | "location" (reserved for the point geometry) |
| Location | Point position of the trunk, EPSG:25832 | Koordinaten (`x`, `y`) | — |
| Location correction | Change of the location of an existing tree to fix a capture error | Lagekorrektur | relocation (a tree is never moved physically) |
| Inspection | Visit of an inspector to a tree with measurements and findings | Kontrolle, Baumkontrolle (`kontrolle`) | survey, check |
| Inspector | Staff member carrying out inspections | Kontrolleur (`kontrolleur`) | — |
| Arborist | Staff member ordering measures | Baumpfleger, Sachverständiger | — |
| Staff member | Employee acting as inspector or arborist (personal data) | — | user (application account ≠ staff member) |
| Vitality class | Vitality rating 1–5 (scale under clarification, Q-002) | Vitalität (`vitalitaet`), Roloff-Stufe | health score |
| Trunk circumference | Circumference of the trunk at 1.0 m, in cm | Stammumfang (`stammumfang`) | diameter (DBH) — not recorded |
| Crown diameter | Average crown diameter, in m | Kronendurchmesser | — |
| Height | Total tree height, in m | Höhe (`hoehe`) | — |
| Defect | Damage or deficiency found at an inspection, with severity | Mangel / Mängel (`maengel`) | damage (too narrow) |
| Measure | Ordered tree-care work (pruning, felling, cabling …) | Maßnahme (`massnahme`), Auftrag | task, job |
| Due date | Date by which a measure must be done | fällig (`faellig`) | deadline |
| Completion date | Date a measure was done | erledigt (`erledigt`) | — |
| Contractor | Company or in-house team carrying out a measure | Firma (`firma`) | supplier |
| Felling | Removal of a tree; the tree remains in the cadastre as `felled` | Fällung, gefällt (`gefaellt`) | deletion |
| Compensation planting | New tree planted to replace one or more felled trees | Ersatzpflanzung | — |
| Exchange file | Monthly JSON delivery to the regional environmental agency | Datenlieferung | — |
| Open data export | Nightly publication of living trees without personal data | Open-Data-Export | — |
