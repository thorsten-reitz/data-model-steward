# Glossary

| Term | Definition | Synonyms / XSD name | Notes |
|------|-----------|----------------------|-------|
| Observation collection | One partner delivery bundling stations, sampling points and observations | `ObservationCollection`; "delivery" | Exchange envelope only (D-001) |
| Station | Fixed monitoring site | `station`, `StationType` | Identified by `stationCode` |
| Station kind | Classification by dominant emission source (traffic / industrial / background) | `stationType`, `StationKindType` | Not the same as area type (urban / rural), Q-008 |
| Sampling point | One pollutant measured at a station, in one unit; owner of a time series | `sampling`, `SamplingPointType` | EEA term; avoid "sensor" / "channel" |
| Pollutant | Observed property, EEA vocabulary code | `pollutant` | |
| Observation | Aggregated measured value for the interval `[begin, end)` | `observation`, `ObservationType`; "measurement", "value" | "observation" preferred |
| Validity | Flag whether a value is valid / below detection limit | `validity` | EEA validity codes (assumed) |
| Verification | Quality-assurance status of a value (verified / preliminary / not verified) | `verification` | EEA verification codes (assumed) |
