# Open questions and assumptions

## Assumptions made to keep moving (confirm or correct)

| ID | Assumption | Affects |
|----|------------|---------|
| A-001 | `stationCode` is unique across all partners and stable; sampling `@id` is stable across deliveries and globally unique | Station / SamplingPoint identity, REST URLs, C-006 |
| A-002 | The 6 pollutants are NO2, PM10, PM2.5, O3, SO2, CO (S1 only names NO2, PM10, O3) | Pollutant code list |
| A-003 | Units use EEA notation `ug.m-3`, `mg.m-3` (CO in mg/m³) | ConcentrationUnit, C-007 |
| A-004 | `validity` / `verification` integers follow the EEA code lists | ObservationValidity, VerificationStatus |
| A-005 | lat/lon are WGS 84 (EPSG:4326) decimal degrees; altitude in metres above mean sea level | Position |
| A-006 | Absent `altitude` and `xsi:nil` altitude both mean "unknown" | Position.altitude |
| A-007 | Observation interval is `[begin, end)`, normally 1 hour; other durations are allowed | Observation, C-001, C-003 |
| A-008 | Each delivery repeats full station/sampling metadata; the latest delivery wins for metadata | Ingest logic |

## Open questions

| ID | Question | Blocking? | Default if unanswered |
|----|----------|-----------|-----------------------|
| Q-001 | Is sampling `@id` stable across deliveries and unique across partners? xs:ID only guarantees uniqueness within one document and must be an NCName (no leading digit, no spaces/colons). | **Yes**, for REST URLs | Assume stable (A-001); otherwise key = stationCode + pollutant + sequence |
| Q-002 | Is station `@id` meaningful or just a document-local anchor? | No | Document-local, ignored (D-005) |
| Q-003 | Which exact pollutant codes do partners send (`PM2.5` vs `PM25`, or Eionet URIs)? | No | Open code list (D-006) |
| Q-004 | Which unit spellings are used (`µg/m3`, `ug/m3`, `ug.m-3`, …)? Always the same unit per pollutant? | No | Open code list; normalise at ingest |
| Q-005 | Meaning of the `validity` and `verification` integers — EEA lists? Any other values in use? | **Yes**, before closing the enums | EEA lists (A-004, D-007) |
| Q-006 | Time zone of `begin`/`end`: is an offset always present? If not, which zone is implied? | **Yes**, for correct ingest | Require offset (C-002), reject otherwise |
| Q-007 | Delivery metadata is missing (partner/sender, creation time, reporting period, delivery id, "replaces" flag). How are corrections and resubmissions recognised? | **Yes**, for idempotent ingest | Upsert by (samplingPointId, begin); last delivery wins |
| Q-008 | Is an area classification (urban/suburban/rural) needed besides `stationType`? | No | Not modelled |
| Q-009 | Delivery frequency (hourly near-real-time vs daily batch) and maximum payload size? | No | Daily batch |
| Q-010 | The namespace contains the version (`…/2.1`). Will 2.2 get a new namespace? That makes every minor change breaking for all XML consumers. | No (future) | Keep the namespace stable for 2.x |
| Q-011 | JSON API naming: keep singular `station`/`sampling`/`observation` arrays (XSD names) or use plural JSON names? | **Yes**, before the API is published | Keep XSD names (D-002) |
| Q-012 | Do API consumers need the history of metadata changes (e.g. station relocation) or of corrected values? | No | Audit only (D-010) |
| Q-013 | Can several sampling points at one station measure the same pollutant (e.g. two instruments)? | No | Allowed |
| Q-014 | Are negative values allowed (instrument noise near zero)? Any plausibility ranges? | No | No range constraint |
