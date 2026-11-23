# Decision log

All decisions below were taken by the modeller on 2026-11-23 under the user's instruction "go ahead with your best judgement — I'll review afterwards". Each is **provisional until the user confirms**.

## D-001 — ObservationCollection is an exchange envelope; stations nested by composition
- **Context**: S1 nests station → sampling → observation inside one root element. In reality a station exists independently of any delivery and is repeated in every delivery.
- **Options**: (a) composition chain as in S1; (b) Station as independent class, collection references stations by code.
- **Choice**: (a) for the exchange view, so the generated XSD/JSON reproduce the S1 tree. The composition `CollectionStations` is explicitly documented as exchange-only.
- **Consequence**: for persistence and the REST resources, Station/SamplingPoint are independent entities with natural keys (D-005); the delivery is a bulk-ingest payload. If a persistence target is added later, revisit (likely: reference instead of composition).

## D-002 — Keep XSD 2.1 names as canonical names
- **Context**: the user wants the XSD-compatible structure and the JSON Schema generated from one model. Renames would break partners.
- **Choice**: role and type names follow S1 exactly: roles `station`, `sampling`, `observation` (singular although multi-valued), types `StationKind`, `Position`, `SamplingPoint`, `Observation` → exported as `StationKindType`, … like S1.
- **Trade-off**: the JSON API inherits singular array names (`"station": [...]`, `"sampling": [...]`). Alternative: plural canonical roles (`stations`, `samplingPoints`, `observations`) plus a target-specific name override for XSD — not supported by the current exporter, would need another post-processing step. Decide before the API is published (Q-011).

## D-003 — Model namespace = S1 targetNamespace
- **Choice**: `model.namespace = http://example.org/airquality/2.1` so the generated XSD has the identical targetNamespace. Side effect: JSON Schema `$id` becomes `http://example.org/airquality/2.1/0.1.0/schema.json`. See Q-010 on version-in-namespace.

## D-004 — Position stays a lat/lon/altitude datatype, not a neutral `geometry`
- **Context**: neutral `geometry` would export as GeoJSON / `xs:anyType` and break the S1 structure.
- **Choice**: datatype `Position` with decimal lat/lon (range facets added) and optional voidable altitude. CRS WGS 84 and metres a.m.s.l. are assumptions (A-005). The API can additionally offer GeoJSON as a derived representation.

## D-005 — Identifiers; XSD `id` attributes handled by a compat post-processing step
- **Context**: S1 has a mandatory `xs:ID` attribute `id` on station and sampling. xs:ID is unique only *within one XML document*, must be an NCName and is not guaranteed stable. Stations also have `stationCode`; sampling points have nothing else.
- **Choice**:
  - Station identity = `stationCode` (natural, external). Station `@id` is document-local and **not** modelled; on export the producer derives it (e.g. `ST_` + stationCode), on import it is ignored.
  - SamplingPoint identity = `samplingPointId` (natural, external), mapped 1:1 to S1 `@id`, assumed stable across deliveries (A-001, Q-001).
  - Observation has no own identifier; natural key (sampling point, begin) — C-003.
- **Export adjustment**: dmtool's XSD exporter emits identifiers as elements and enumerations on `xs:string`. `tools/xsd_compat_2_1.py` deterministically turns the generated `airquality.xsd` into `airquality-2.1-compat.xsd`: adds `@id` (xs:ID, required) to StationType and SamplingPointType, drops the `samplingPointId` element, sets the validity/verification base to `xs:int`, sets `version="2.1"`. Verified: `examples/delivery.xml` is valid against S1 and against the compat XSD.
- The plain `airquality.xsd` is the model-native XSD and is **not** wire-compatible with 2.1.
- No NCName pattern on `samplingPointId` in the model: XSD regex (implicitly anchored) and JSON Schema regex (unanchored) cannot share one pattern string through the exporter.

## D-006 — Pollutant and unit as extensible code lists
- **Context**: S1 types both as free `xs:string`; pollutant documented as "EEA pollutant vocabulary".
- **Choice**: extensible enumerations (exported as plain string + known values) so 2.1 data is never rejected. Option to close them (or validate against the Eionet register at ingest) once the 6 pollutants and unit spellings are confirmed (Q-003, Q-004).

## D-007 — validity and verification as closed integer code lists (EEA)
- **Context**: S1 has bare `xs:int` with no documentation.
- **Choice**: closed enumerations with EEA codes (validity −99, −1, 1, 2, 3; verification 1, 2, 3). JSON Schema → integer `enum`; compat XSD → `xs:int` with enumeration facets.
- **Compatibility note**: this is *narrower* than S1 — a 2.1 document with e.g. `<validity>0</validity>` is valid against S1 but rejected by the compat XSD. Intentional tightening, needs partner confirmation (Q-005).

## D-008 — JSON Schema root = delivery envelope; API resources use the `$defs`
- **Context**: ~57,600 observations/day (400 × 6 × 24) ≈ 21 M/year; a full-day delivery is roughly 8–10 MB of JSON.
- **Choice**: JSON Schema root is `ObservationCollection` (bulk ingest, e.g. `POST /deliveries`). REST read resources (`/stations`, `/stations/{code}/sampling-points`, `/sampling-points/{id}/observations?from=&to=`) should reference `$defs/Station`, `$defs/SamplingPoint`, `$defs/Observation`, with observations paginated / time-windowed rather than embedded.
- **Limitation**: `$defs/Station` as generated embeds sampling points and observations; resource-level variants without the nested arrays need an OpenAPI layer (not yet generated).

## D-009 — JSON mapping of the nillable `value`
- S1: `value` is mandatory but nillable (element present, `xsi:nil="true"`). The exporter maps voidable to `number | null` and does not list it in `required`, so in JSON an absent `value` and `null` are equivalent. Accepted; the API should always emit `null` explicitly.

## D-010 — Data history: audit only
- Station and SamplingPoint metadata and observations (which get corrected when verification moves from 3 to 1) get `history.mode: audit` with logical deletion. No versioned/bitemporal history in the exchange payloads, so the 2.1 structure is unchanged. Revisit if consumers need "as reported on date X" (Q-012).
