# Sources

| ID | Title | Location | Version/date | Kind | Covers | Authority |
|----|-------|----------|--------------|------|--------|-----------|
| S1 | Partner air quality observation exchange schema | `../observations.xsd` | XSD v2.1, ns `http://example.org/airquality/2.1`; received 2026-11-23 | XSD | Stations, position, station kind, sampling points (pollutant, unit), hourly observations (begin/end/value/validity/verification) | normative for the partner wire format |
| S2 | User brief (request of 2026-11-23) | conversation | 2026-11-23 | prose | Purpose (REST API + XSD-compatible exchange from one model); volumes: ~400 stations, 6 pollutants, ~24 hourly values per pollutant per station per day | normative for purpose/NFR |

Referenced but not ingested: EEA/Eionet air quality vocabularies (pollutant, concentration unit, validity, verification). S1 only names the pollutant vocabulary; the others are assumed (A-002..A-004).
