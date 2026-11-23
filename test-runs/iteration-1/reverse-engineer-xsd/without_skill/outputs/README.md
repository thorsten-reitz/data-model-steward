# Air quality observations: canonical data model

The source of truth is **`model/airquality.model.yaml`**. Everything in `generated/` is derived from it:

| File | Purpose |
|------|---------|
| `generated/observations.schema.json` | JSON Schema (draft 2020-12) for the REST API. The root is a full delivery (`ObservationCollection`). The API resources `ObservationRecord`, `StationSummary` and every entity are under `$defs`. |
| `generated/observations.compat.xsd` | XSD that accepts exactly what partner schema 2.1 accepts: same namespace, element names, order, cardinalities and types. It also adds documentation. |
| `generated/observations.strict.xsd` | The same structure with the canonical constraints applied: mandatory UTC offset, code lists, coordinate ranges, uniqueness. This is a proposal for a v2.2 partner schema. |
| `xsd-review.md` | Ambiguities and problems in the v2.1 XSD, with the decision taken for each. |
| `samples/*.xml` | Test deliveries, named `__valid` or `__compatonly` (accepted by 2.1 but rejected by the canonical rules). |

Regenerate and verify (needs PyYAML, lxml and jsonschema):

```
python generate.py --check
```

`--check` validates each sample against the original 2.1 XSD, the compat XSD, the strict XSD, and the JSON Schema after an XML-to-JSON conversion. It fails if the compat XSD ever disagrees with the original.

## Entities

```
ObservationCollection (delivery)
 └─ Station 1..*            key: id (xs:ID)   business key: stationCode
     ├─ Position 1          lat, lon (WGS84 assumed), altitude?
     ├─ stationType         StationKind {traffic, industrial, background}
     └─ SamplingPoint 1..*  key: id (xs:ID)   pollutant + unit
         └─ Observation 0..*  key: (samplingPoint, begin)
               begin, end (with offset), value (number|null),
               validity (ValidityFlag), verification (VerificationFlag)
```

The XML and JSON names differ only for lists: `station` / `stations`, `sampling` / `samplingPoints`, `observation` / `observations`.

## Recommended API shape (volume: ~57,600 observations/day)
- `POST /deliveries`: accepts an `ObservationCollection`, as XML (validated against the compat XSD) or JSON. Ingest upserts observations on (samplingPointId, begin).
- `GET /stations`, `GET /stations/{id}`: `StationSummary`, without observations.
- `GET /observations?station=&pollutant=&from=&to=&cursor=`: a paged list of flat `ObservationRecord` items.
