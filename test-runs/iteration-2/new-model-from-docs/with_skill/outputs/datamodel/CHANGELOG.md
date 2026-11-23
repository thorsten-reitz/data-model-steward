# Changelog

## Unreleased — 0.1.0 draft (2026-11-23)
Sources: S1 (requirements v0.3), S2 (legacy schema 2026-09-30), S3 (GBIF Backbone, link only), S4 (Roloff vitality key)
### Added
- Classes Tree, TreeLocationCorrection, Species, Site, StaffMember, Contractor, Inspection, InspectionDefect, Measure; code lists TreeStatus, FellingReason, VitalityClass, DefectType, DefectSeverity, MeasureType, MeasurePriority, MeasureStatus, SiteType; rules C-001 … C-011 (D-001 … D-014)
- Draft exports in `exports/draft/` (PostgreSQL DDL, JSON Schema, Mermaid diagram); hand-written `handwritten/` (exchange file envelope, tuning.sql, example file, legacy mapping)
### Compatibility
- First draft, nothing released. `dmtool release` is blocked until the `proposed` elements are confirmed and Q-001 is answered.
