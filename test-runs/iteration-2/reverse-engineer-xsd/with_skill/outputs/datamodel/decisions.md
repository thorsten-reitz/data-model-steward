# Decisions

All decisions below were taken by the assistant on the user's instruction "just go ahead with your best judgement"; they await review (2026-11-23).

## D-001 The model reproduces XSD 2.1 on the wire (2026-11-23)
Context: partners already deliver XSD 2.1 documents; the REST API is new.
Options: (a) canonical model shaped so the generated XSD accepts exactly the 2.1 documents; (b) clean-slate model plus a separate mapping to 2.1.
Choice: (a). Namespace `http://example.org/airquality/2.1` kept; `@id` kept as XML attribute `xs:ID` (`xml.attribute`); element names `station`, `sampling`, `observation` kept via `names.xsd`, while the canonical/JSON role names are `stations`, `samplingPoints`, `observations`. complexType names match S1 (StationType, PositionType, SamplingPointType, ObservationType, StationKindType).
Rationale: one source of truth without a hand-written mapping layer. Verified with lxml: a sample and 10 variants get the same verdict from S1 and the generated XSD, except the lat/lon range of D-002.
Consequence: the XSD `version` attribute now carries the model version (0.1.0 draft), not "2.1"; see Q-009.

## D-002 Position stays lat/lon/altitude, with range checks (2026-11-23)
Options: neutral `geometry` (GeoJSON in JSON, GML in XSD) vs. a Position datatype.
Choice: Position datatype with lat in [-90, 90], lon in [-180, 180].
Rationale: `geometry` would change the XML structure. The range facets are the only intended tightening vs. S1: a document with lat 95 is valid against S1 but not against the generated XSD. Such values are errors anyway; remove the facets if byte-for-byte acceptance is required.

## D-003 Code lists: open (extensible) and referenced to EEA AQD vocabularies (2026-11-23)
Context: S1 names the EEA pollutant vocabulary for `pollutant`; `validity`/`verification` are bare xs:int whose values match the EEA AQD flags.
Choice: Pollutant, ObservationValidity, ObservationVerification and ConcentrationUnit are extensible enumerations, so the generated XSD keeps unrestricted xs:string / xs:int (wire-compatible) and the JSON Schema lists known values as `examples`, with `x-vocabulary`/`x-enumUris`. Pollutant carries the notation (NO2), not the numeric EEA id (8), because S1's example says so.
Status: proposed, pending Q-002, Q-003, A-003, A-004. Several value URIs and labels were not verified on the register (unreachable from here).

## D-004 Compositions nested in both targets (2026-11-23)
Station > SamplingPoint > Observation are compositions, nested in XSD (as in S1) and in JSON. For the REST API the same `$defs` serve as resource bodies (e.g. `GET /stations/{stationCode}` returns a Station, `GET /sampling-points/{id}/observations?from=&to=` a paged Observation array); the nested delivery document is the bulk-ingest shape. See Q-008.
