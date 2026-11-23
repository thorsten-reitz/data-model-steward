# Changelog

## 0.1.0 — draft (2026-11-23, not released)
- Initial model reverse-engineered from partner XSD 2.1 (S1).
- Added: ObservationCollection, Station, SamplingPoint, Observation; datatype Position; enumerations StationKind, Pollutant (extensible), ConcentrationUnit (extensible), ObservationValidity, VerificationStatus; constraints C-001..C-007.
- Exports: JSON Schema 2020-12, model-native XSD, partner-compatible XSD 2.1 (via D-005 post-processing), Mermaid diagram, sample delivery in XML and JSON.
- Tightened vs. S1 (pending confirmation): validity/verification code lists, lat/lon ranges.
