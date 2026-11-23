# Open questions and assumptions

## Questions

- **Q-001 (blocking for persistence and API URLs)** Are `station/@id` and `sampling/@id` stable across deliveries, or generated per document? xs:ID is only unique within one document and cannot start with a digit (so no UUIDs or purely numeric codes). Proposal: Station keyed by `stationCode`; SamplingPoint keyed by `@id` only if stable, otherwise by (stationCode, pollutant).
- **Q-002** Pollutant: notation (`NO2`) or EEA numeric id (`8`) / URI? S1 says "code from the EEA pollutant vocabulary, e.g. NO2", but in that vocabulary the identifier is numeric and `NO2` is the notation. Do partners spell PM2.5 consistently? Proposal: notation, checked against the known list with warnings.
- **Q-003** Unit: which strings do partners send (`ug.m-3`, `µg/m3`, `ug/m3` ...)? Proposal: adopt the EEA `uom/concentration` notations and map variants on ingest. Values not verified.
- **Q-004** Altitude: is there a difference between an omitted `altitude` and `xsi:nil`? Proposal: treat both as "unknown"; the API returns `null`.
- **Q-005** Time: do `begin`/`end` always carry a UTC offset? Is the interval `[begin, end)`? Hourly means only, or other averaging periods too (the schema allows any interval)?
- **Q-006** Station classification: adopt EEA `aq/stationclassification` URIs? The area type (urban/suburban/rural), which EEA reporting uses alongside traffic/industrial/background, is missing in S1.
- **Q-007** Re-deliveries: do partners resend observations with an updated `verification` or `value`? Proposal: upsert by (samplingPoint, begin) and keep an audit trail (history: audit).
- **Q-008** Delivery granularity: how often and how much per document (hourly push, daily file, full history)? Station master data is repeated in every delivery; which copy wins when they differ?
- **Q-009** Versioning: should the first model release be numbered 2.1.0 to mirror the partner XSD? Should the namespace stay version-bearing (`.../2.1`)? A version in the namespace makes every future version a namespace change for partners.
- **Q-010** Strings have no length or pattern limits in S1 (stationCode, name, operator, ids). Any known limits? Adding them would narrow the wire format.
- **Q-011** Should `operator` be an organisation code/URI rather than free text?

## Assumptions

- A-001 Partners validate strictly against XSD 2.1, so `compatibility.consumers: strict`. (confirmed: no)
- A-002 `stationCode` is unique and stable across deliveries (persistent station identifier). (confirmed: no)
- A-003 The six pollutants are NO2, PM10, PM2.5, O3, SO2, CO. (confirmed: no)
- A-004 `validity` and `verification` use the EEA AQD observation validity / verification codes. (confirmed: no)
- A-005 Coordinates are WGS 84 (EPSG:4326) decimal degrees; altitude in metres above mean sea level. (confirmed: no)
- A-006 The observation interval is `[begin, end)`, normally one hour. (confirmed: no)
