# Urban Tree Cadastre – Requirements (v0.3, Parks Department)

## Background
The city maintains ~180,000 street and park trees. Today they are kept in an old Access/PostgreSQL
hybrid (see legacy_trees.sql). We want a new tree cadastre that the parks department uses daily and
that we can share with the regional environmental agency and the open data portal.

## Use cases
UC1 – Register a tree: an inspector records a newly planted tree with its location (point, in
ETRS89 / UTM zone 32N), species (botanical name from the city's species list, ~900 entries, which
the arborist team extends a few times a year), planting year (if known), and the park or street
segment it belongs to.

UC2 – Inspect a tree: inspectors visit each tree at least once a year. An inspection records date,
inspector, trunk circumference (cm), crown diameter (m), height (m), vitality class (1–5 according
to the Roloff scale) and any number of defects (e.g. "deadwood", "cavity", "root damage" – from a
fixed list maintained by the department) with severity low/medium/high. Inspections must never be
deleted; auditors need to see who changed what.

UC3 – Order a measure: from an inspection, an arborist can order measures (pruning, felling,
cabling, …) with a due date and a priority. A measure is later marked as done, with completion date
and the contractor that did it.

UC4 – Fell a tree: when a tree is felled it is not deleted – it remains in the cadastre with the
felling date and reason, because compensation planting must be tracked (a felled tree may be
replaced by one or more new trees).

UC5 – Publish: once a night, all living trees (id, species, planting year, location, latest vitality)
are exported as open data. The regional agency receives a monthly exchange file with trees,
inspections and measures.

## Volumes and performance
- 180,000 trees, +3,000/year. ~200,000 inspections/year; keep 30 years.
- ~25,000 measures/year.
- Map view must load all trees in a bounding box of ~5,000 trees in under 1 s.
- Inspectors work offline on tablets and sync in the evening.

## Other
- Inspector names are personal data; the open data export must not contain them.
- The location of a tree can be corrected later (GPS errors); we need to know the previous location
  and when it was corrected.
