# Sources

| ID | Title | Location | Version/date | Kind | Covers | Authority |
|----|-------|----------|--------------|------|--------|-----------|
| S1 | Partner air quality exchange schema | ../observations.xsd | version 2.1 (namespace http://example.org/airquality/2.1) | XSD | Delivery document: stations, sampling points, hourly observations | normative (wire format partners use today) |
| S2 | EEA/Eionet Data Dictionary, AQD vocabularies: pollutant, observationvalidity, observationverification (candidates: uom/concentration, stationclassification) | http://dd.eionet.europa.eu/vocabulary/aq/ | retrieved 2026-11-23 via web search only (register itself unreachable from here) | code lists | Pollutant codes (named in S1), validity and verification flags (assumed) | normative for EU AQ reporting |
| S3 | User brief | conversation 2026-11-23 | 2026-11-23 | prose | Purpose (REST API + XSD-compatible exchange from one model); volumes ~400 stations, 6 pollutants, 24 hourly values/day | user |

## Ingestion summary (S1)

| XSD construct | Model element | Note |
|---|---|---|
| element `ObservationCollection` (anonymous type) | class ObservationCollection | root; no metadata (sender, creation time, period) |
| `StationType` (with `@id` xs:ID) | class Station | identity: stationCode assumed persistent, `@id` document-local |
| `PositionType` (no identity) | datatype Position | CRS, altitude unit/datum unstated |
| `StationKindType` (xs:enumeration) | closed enumeration StationKind | |
| `SamplingPointType` (with `@id` xs:ID) | class SamplingPoint | composition of Station |
| `pollutant` xs:string + doc "EEA pollutant vocabulary" | extensible enumeration Pollutant (vocabulary S2) | notation vs. numeric code ambiguous |
| `unit` xs:string | extensible enumeration ConcentrationUnit | no code list named |
| `ObservationType` (no identity) | class Observation (composition part) | natural key (samplingPoint, begin) implied, not declared |
| `validity`, `verification` xs:int | extensible integer enumerations (EEA AQD assumed) | no code list named |
| `nillable` on `value`, `altitude` | voidable | |

Volumes (S3): 400 stations x 6 pollutants x 24 h = 57,600 observations/day, about 21 M/year.
