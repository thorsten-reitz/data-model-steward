# Changelog — Tree Cadastre model

## 0.1.0 — 2026-11-23 (draft, not released)
Sources: S1 (requirements v0.3), S2 (legacy schema export 2026-09-30)
### Added
- Classes: Species, Site (abstract), Park, StreetSegment, Tree, LocationCorrection, Inspection, Measure, Contractor, StaffMember.
- Datatype: DefectFinding. Enumerations: TreeStatus, FellingReason, DefectType, DefectSeverity, MeasureType, MeasurePriority, MeasureStatus.
- Rules C-001 … C-011.
- Exports in `exports/0.1.0/`: `schema.sql` (generated), `schema.json` (generated), `exchange-file.schema.json` (hand-written envelope, D-010), `tuning.sql` (hand-written, D-012), `examples/exchange-file.example.json`.
### Compatibility
- First draft; no released predecessor. Not released: 18 assumptions and 8 open questions pending (`open-questions.md`); 14 elements still `proposed`.
