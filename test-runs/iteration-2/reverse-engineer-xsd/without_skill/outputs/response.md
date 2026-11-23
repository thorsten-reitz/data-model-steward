I've turned the 2.1 XSD into one canonical model file. Both the XML schema and the JSON Schema are now generated from it. A test script confirms the generated XSD is structurally identical to your partners' file, so partner files validate exactly as before. The JSON Schema is deliberately stricter in a few places. I also found 16 problems in the XSD, and five of them are serious enough to raise with the partners.

## What's in the folder

| Path | What it is |
|------|------------|
| `model/airquality.model.yaml` | **The canonical model, the one file you edit.** Classes, fields, cardinality, nullability, code lists, the XML names where they differ from JSON, and my assumptions. |
| `tools/generate.py` | Writes `generated/observations.xsd` and `generated/airquality.schema.json` from the model. |
| `generated/observations.xsd` | The 2.1-compatible XSD, now with documentation added. |
| `generated/airquality.schema.json` | **The JSON Schema** (draft 2020-12): a root bulk document plus `Station`, `Position`, `SamplingPoint`, `Observation` and the code lists, so you can reference each one from OpenAPI. |
| `tools/convert.py` | Converts XML ⇄ JSON, driven by the same model. |
| `examples/sample.xml`, `examples/sample.json` | A small 2.1 delivery and its JSON version. |
| `tests/run_tests.py` | The compatibility and strictness tests. |
| `xsd-review.md` | **All findings in detail** (Q1–Q16) and the API design notes (D1–D3). |

To regenerate and test: `python tests/run_tests.py`. It needs PyYAML, lxml and jsonschema. All checks pass:

- The generated XSD has the same structure as your partners' 2.1 file. Only the added documentation and the order of the type definitions differ.
- In 17 test documents, the original and generated XSDs accept and reject the same ones.
- Converting XML → JSON → XML gives back the same data.

## The model in brief

```
ObservationCollection 1─* Station 1─1 Position
                          Station 1─* SamplingPoint (one pollutant + unit) 1─0..* Observation
Observation = begin, end, value (nullable), validity, verification
```

- **JSON names match the XML names.** The exceptions are the repeated elements, which become plural arrays: `station` → `stations`, `sampling` → `samplingPoints`, `observation` → `observations`. The model records each XML name, so the converter handles the mapping.
- **The JSON Schema rejects some data the 2.1 XSD accepts.** The generated XSD is exactly as permissive as 2.1. The JSON Schema additionally requires:
  - a UTC offset on timestamps
  - latitude/longitude within valid ranges
  - non-empty pollutant and unit
  - validity/verification from a known code list
  - no NaN/INF values

  So a partner file can be valid 2.1 and still fail conversion. The tests cover each of these cases.

## Questions for the partners (High severity)

1. **Q1 – Which identifier is the stable one?** Is it the station's `@id` or `stationCode`? And is a sampling point's `@id` stable from one delivery to the next? I assumed `stationCode` is the business key. The answer decides your API URLs and database keys.
2. **Q6 – What do `validity` and `verification` mean?** They are bare integers with no code list. I assumed the EEA e-Reporting codes:
   - validity: 1, 2, 3, -1, -99
   - verification: 1, 2, 3

   The JSON Schema enforces these codes, so they must be confirmed.
3. **Q3 – Which coordinate system?** None is stated, and there are no range limits. I assumed WGS 84 in decimal degrees.
4. **Q3b – Time zones.** `xs:dateTime` allows timestamps without a time zone. For hourly data that is ambiguous, especially when clocks change for daylight saving. The API requires an offset.
5. **Q5 – Free-text pollutant and unit.** The XSD's own documentation says pollutant should be an EEA vocabulary code, but nothing enforces it. Unit is also free text, so expect variants like `µg/m³` / `ug/m3` / `ug.m-3`. Getting CO's mg/m³ wrong changes values by a factor of 1000. Tell me which six pollutants you receive and I'll add them as a code list; I guessed NO2, PM10, PM2.5, O3, SO2 and CO but did not enforce that.

The Medium findings need checks in the ingest service, because the schemas can't catch them:

- a nil `value` can still be flagged "valid" (Q7)
- there are no uniqueness rules for station codes, for a pollutant within a station, or for the same hour within a sampling point (Q8)
- `end > begin` is not enforced (Q9)

Medium findings that are design issues rather than ingest checks:

- there is no delivery metadata, so a correction file can't be told apart from an original (Q13)
- the version is part of the namespace, so even a 2.2 breaks every XPath (Q14)

## API shape (D1)

Your volume is 400 stations × 6 pollutants × 24 hours = about **57,600 observations a day**, or about **21 million a year**. A full day in one 2.1 document is about 13 MB.

Use the nested `ObservationCollection` only for **bulk ingest**. For reads, serve:

- `/stations`
- `/stations/{code}/sampling-points`
- a flat, paginated `/observations?station=&pollutant=&from=&to=`

Those endpoints can reference the `$defs` in the schema. I haven't modelled the flat observation row or the station-without-observations view yet. Both are simple projections of the model, but they depend on endpoint decisions you haven't made. Store observations keyed by (sampling point, `begin`) and partition them by month.

## About the model format

The model file uses a small YAML format of my own rather than LinkML. LinkML can't generate an XSD, and exact 2.1 compatibility was the main requirement. The generator and converter together are about 400 lines of Python. If you'd rather standardise on LinkML later, the model maps onto it almost one to one.
