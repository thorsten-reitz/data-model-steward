# Changelog

## Unreleased (0.1.0 draft), 2026-11-23
- Added: initial model reverse-engineered from partner XSD 2.1 (S1): ObservationCollection, Station, SamplingPoint, Observation, Position, StationKind, Pollutant, ConcentrationUnit, ObservationValidity, ObservationVerification; constraints C-001 to C-005.
- Wire compatibility with XSD 2.1 checked with lxml (D-001); only intended difference: lat/lon range facets (D-002).
- Not released: proposed elements and open questions Q-001 to Q-011 await review.
