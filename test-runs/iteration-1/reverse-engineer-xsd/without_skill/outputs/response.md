I've reverse-engineered the v2.1 XSD into one model file. A generator builds both the JSON Schema for your API and an XSD that accepts exactly what 2.1 accepts. I checked the generated XSD against the original with 4 test files and it agrees on every one.

## What you have now
- **`model/airquality.model.yaml`**: the canonical model and the one place to edit. It has 4 entities (Station, Position, SamplingPoint, Observation) and 3 code lists (StationKind, ValidityFlag, VerificationFlag). It records the XML names (`station`, `sampling`, `observation`) and the JSON names (`stations`, `samplingPoints`, `observations`) for each element. Each element is linked to its finding in the review.
- **`generate.py`**: builds everything in `generated/` from the model. `python generate.py --check` also tests the sample files.
  - `observations.schema.json`: JSON Schema (draft 2020-12). The root is a full delivery. It also defines two shapes for the API: `ObservationRecord`, one flat observation for paged lists, and `StationSummary`, a station without its observations.
  - `observations.compat.xsd`: accepts exactly what 2.1 accepts (same namespace, names, order and cardinalities). Use it to validate what partners send.
  - `observations.strict.xsd`: the same structure with the model's rules applied. You could offer it to partners as v2.2.
- **`xsd-review.md`**: 16 findings, each with a severity, the decision I took, and the question to put to partners.
- **`samples/`**: 4 test files. `--check` passes on all of them: the original and compat XSDs agree on every file. The test files with a missing timezone, an unknown validity code, and a latitude of 152 all pass the original 2.1 XSD, but the strict XSD and the JSON Schema reject them.

## Most important findings
1. **Timezones are optional in the XSD** (`xs:dateTime`). A value like `2026-11-22T00:00:00` is ambiguous, and in local time the hour when the clocks go back occurs twice. The model now requires a UTC offset. `format: date-time` alone isn't enforced by default in draft 2020-12, so the JSON Schema also uses a pattern. Partners on 2.1 can still send timestamps without an offset, so ingest has to reject them or apply a timezone configured per partner.
2. **`validity` and `verification` are plain integers with no list of codes.** I assumed the EEA codes: validity -99, -1, 1, 2, 3 and verification 1, 2, 3. Please confirm these.
3. **`pollutant` and `unit` are free text.** The XSD doesn't say which 6 pollutants are used, and units can be spelled several ways (`µg/m3`, `ug/m3`). Both should become fixed lists once partners confirm the values.
4. **`xs:ID` ids** can't start with a digit. Stations and sampling points share one id space. They are only guaranteed unique within one document, not stable from one delivery to the next. There is also no rule about whether `id` or `stationCode` is the real key for a station.
5. **Volume and corrections.** 400 stations × 6 pollutants × 24 hours is about 57,600 observations a day, or about 21 million a year. The XSD has no way to mark a re-sent or corrected value. I modelled the nested XML layout only as the bulk upload format. The API serves flat, paged observations, and re-sent values replace the old ones based on sampling point and start time.

Smaller findings in the review:
- No rule that `end` is after `begin`, and hourly intervals aren't stated.
- `xs:double` accepts NaN/INF, which JSON can't represent.
- Unknown altitude can be sent two ways (left out or empty), with no unit.
- The coordinate system isn't stated.
- There is no sender or schema version in the files themselves.
- The version is part of the namespace.
- Some names are confusing (`stationType` vs `StationType`).

## Assumptions to confirm
- Coordinates are WGS84.
- Altitude is in metres above sea level.
- Intervals include `begin` and exclude `end`, and values are hourly means.
- Station `id` values stay the same across deliveries.

Each assumption is a one-line change in the model file, followed by `python generate.py`.

## Not covered by the schemas
Some rules can't be expressed in XSD or JSON Schema and need code in ingest:
- `end` is after `begin`, and the interval is 1 hour
- Handling timestamps sent without a timezone
- Holding back unknown codes
- Turning NaN into null
- Normalising unit spellings
- Replacing re-sent values

The API's paging envelope and error formats aren't modelled yet either.
