# Sources register

| ID | Title | Location | Version/date | Kind | Covers | Authority |
|----|-------|----------|--------------|------|--------|-----------|
| S1 | Urban Tree Cadastre – Requirements (Parks Department) | `../requirements.md` | v0.3 (received 2026-11-23) | prose / use cases UC1–UC5, volumes, NFRs | trees, inspections, defects, measures, felling & compensation, publication, volumes, personal data, location corrections | normative (wins in conflicts) |
| S2 | Legacy tree database schema | `../legacy_trees.sql` | export 2026-09-30 | PostgreSQL DDL (tables `baum`, `kontrolle`, `massnahme`) | current persistence; attribute types/lengths; source for data migration | informative |

## Notes per source

- **S1** – No section numbers; references use use-case IDs (UC1–UC5) and headings ("Volumes and performance", "Other").
- **S2** – German column names (see `glossary.md`). Contains free-text workarounds that were *not* copied into the model:
  `baum.art_lat` (free-text species), `baum.strasse`/`baum.park` (free text instead of references),
  `baum.gefaellt` ('J'/'N' flag), `kontrolle.maengel` (comma-separated defect list), `massnahme.firma` (free text).
  Technical columns `angelegt_am`, `geaendert_am`, `geaendert_von` are evidence for an audit requirement and are
  covered by `history` instead of attributes. No row counts or indexes in the dump. Legacy column → new model mapping: `legacy-mapping.md`.
