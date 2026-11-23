# Review of partner XSD `observations.xsd` (version 2.1)

Findings from reverse-engineering the XSD into `model/airquality.model.yaml`.
IDs (Q1, Q2, ...) are referenced from the model and the tests.

Severity: **High** = can corrupt or lose data, or blocks a design decision.
**Medium** = causes integration or quality problems. **Low** = cosmetic or for later.

"Handling" says what the canonical model does now. Anything marked
*JSON-only* is enforced in the JSON Schema but deliberately **not** in the
generated XSD, so the generated XSD stays exactly as permissive as 2.1.

## Summary

| ID | Severity | Topic | Handling |
|----|----------|-------|----------|
| Q1 | High | Two station identifiers (`@id` and `stationCode`); unclear which one is stable | `stationCode` assumed to be the business key; `id` kept as a document-local id |
| Q2 | Medium | `xs:ID` limits: NCName syntax, one uniqueness space shared by stations and sampling points | Kept; the JSON pattern restricts ids to ASCII NCName |
| Q3 | High | No CRS for `lat`/`lon`; no range limits | Assumed WGS 84; range check (JSON-only) |
| Q3b | High | `xs:dateTime` allows timestamps without a UTC offset | Offset required (JSON-only) |
| Q4 | Low | `altitude` can be both absent and nil; no unit | Both mean "unknown"; assumed metres a.s.l. |
| Q5 | Medium | `pollutant` and `unit` are free text, although documented as vocabulary codes | Kept as strings; non-empty (JSON-only) |
| Q6 | High | `validity`/`verification` are bare `xs:int` with no code list | Assumed EEA AQD code lists; enumerated (JSON-only) |
| Q7 | Medium | Nil `value` is not tied to `validity` | Documented; needs a business rule |
| Q8 | Medium | No uniqueness constraints (`stationCode`, pollutant per station) | Documented; needs a business rule |
| Q9 | Medium | Observation interval: `end > begin`, averaging period, open/closed interval, duplicates | Assumed [begin, end); needs a business rule |
| Q10 | Low | `stationType` has no area type (urban/suburban/rural); closed enum | Kept |
| Q11 | Low | `operator` is free text | Kept |
| Q12 | Medium | All observations are nested inside the station document | API design note D1 |
| Q13 | Medium | No delivery metadata (sender, creation time, period, corrections) | Documented |
| Q14 | Medium | Version is part of the namespace URI | Documented |
| Q15 | Medium | `xs:double` allows NaN/INF/-INF, which JSON cannot represent | Rejected in conversion |
| Q16 | Low | Naming: element `stationType` vs complex type `StationType` | Canonical enum named `StationKind` |

## Details

### Q1 Station identity: `@id` vs `stationCode` (High)
`StationType` has a required `xs:ID` attribute **and** a required
`stationCode`. The XSD does not say:
- whether `@id` is stable across deliveries or only unique within one document,
- whether `stationCode` is unique, and in which scope (partner, country, EEA-wide),
- how `@id` and `stationCode` relate (for example `@id = "ST_" + stationCode`).

The same applies to `SamplingPointType/@id`: it is the only sampling point
identifier, so we cannot tell whether a sampling point with the same pollutant
in tomorrow's file is the same series.

**Assumption:** `stationCode` is the stable business key. A sampling point is
identified by its `@id` if partners keep it stable. Otherwise we fall back to
(`stationCode`, `pollutant`), which only works if Q8 holds.
**Ask the partners.** This decides the API URLs and the database keys.

### Q2 `xs:ID` side effects (Medium)
- `xs:ID` must be an NCName. It cannot start with a digit and cannot contain
  `:` or spaces, so a raw numeric id like `12345` is invalid (checked by a test).
- Every `xs:ID` value in a document must be unique. Station ids and sampling
  point ids share one space, so a sampling point cannot reuse its station's id (checked by a test).
- Uniqueness covers only one document. It says nothing about identity across files.

The JSON Schema uses the ASCII subset of NCName (`^[A-Za-z_][A-Za-z0-9._-]*$`),
so every id the API accepts can also be written back to XML. JSON Schema cannot
express document-wide uniqueness, so the ingest service has to check it.

### Q3 Coordinates without CRS (High)
`lat`/`lon` are bare `xs:decimal`. There is no CRS, no axis order and no
range. A partner who sends ETRS89/UTM metres (for example `lat=5820000`) passes
validation. **Assumption:** WGS 84 / EPSG:4326 in decimal degrees. The JSON Schema
enforces lat in [-90, 90] and lon in [-180, 180] (JSON-only). The difference
between ETRS89 and WGS 84 is below 1 m, which is fine here.

### Q3b Timestamps without time zone (High)
`xs:dateTime` accepts `2026-11-22T00:00:00` with no offset. For hourly data
this is ambiguous by up to ±14 h, and at the DST switch the same local hour
occurs twice. The JSON Schema requires `Z` or `±hh:mm` (JSON-only, enforced by a
regex pattern so it works even where `format` is not checked). XML from partners
without an offset is rejected at conversion. If that turns out to be common,
agree on a default zone per partner. Do **not** guess one silently.

### Q4 Altitude (Low)
`altitude` is `minOccurs="0"` **and** `nillable="true"`, so there are two
ways to say "unknown". The unit and the vertical datum are not given.
**Assumption:** metres above mean sea level. Absent and nil mean the same.
In JSON the field is optional and nullable (mirrors XML 1:1). A future version
should keep only one of the two.

### Q5 Pollutant and unit are free text (Medium)
The documentation says *"Code from the EEA pollutant vocabulary, e.g. NO2,
PM10, O3"*, but the type is `xs:string`. Problems:
- The EEA vocabulary (`http://dd.eionet.europa.eu/vocabulary/aq/pollutant/`)
  identifies pollutants by numeric URI (NO2 = `.../8`, PM10 = `.../5`), and
  its "notation" labels are not all as simple as the example. Expect variants
  like `NO2`, `no2`, `Nitrogen dioxide`, `PM2.5`/`PM25`.
- `unit` is free text: `µg/m³`, `ug/m3`, `ug.m-3`, `mg/m3` will all appear.
  CO is usually reported in mg/m³ and the others in µg/m³, so mixing them up
  changes values by a factor of 1000.

**Handling:** both are non-empty strings in JSON. The ingest service should
map them to a controlled list (6 pollutants, about 2 units) and reject unknown
values. I did not hard-code an enum because you did not say which 6 pollutants
you get. They are probably NO2, PM10, PM2.5, O3, SO2 and CO. Once you confirm, add them as an enum in
the model (one change, both schemas regenerate).

### Q6 `validity` / `verification` codes undefined (High)
Both are mandatory `xs:int` with no code list and no documentation. The names
match the EEA AQD e-Reporting flags, so I **assumed**:
- validity: `1` valid, `2` valid but below detection limit, `3` valid but
  below limit of quantification, `-1` not valid, `-99` not valid
  (maintenance/calibration)
- verification: `1` verified, `2` preliminary verified, `3` not verified

The JSON Schema enforces these (JSON-only). An XML file with, say,
`validity=0` is valid 2.1 but fails conversion. That is deliberate: an
unknown quality flag should be looked at, not stored. **Confirm with the
partners.** If they use other codes, edit the two enums in the model.

### Q7 Nil value vs. validity (Medium)
`value` is `nillable`, but nothing links a nil value to a negative
`validity`. `value=nil, validity=1` ("valid, but no value") passes both
schemas (test case "nil value flagged valid"). Suggested business rule at
ingest: `value == null` ⇒ `validity < 0`. Also `value` is `minOccurs=1`,
so a missing measurement is either a nil observation or a missing
`observation` element, and the XSD does not say which to use.

### Q8 Missing uniqueness constraints (Medium)
There is no `xs:unique`/`xs:key` for:
- `stationCode` within a document,
- `pollutant` within a station. Two sampling points for NO2 at the same station
  are valid (test case). That may be legitimate (two instruments), but then the
  sampling point `@id` must be stable (Q1),
- `begin` within a sampling point (duplicate hours).

Adding them to the XSD would reject documents that are valid 2.1 today, so the
generated XSD does not have them. Check them at ingest. Note that partner
corrections or re-deliveries need an "upsert by (sampling point, begin)" rule.

### Q9 Observation interval semantics (Medium)
- `end > begin` is not enforced (end-before-begin passes; test case).
- The averaging period exists only as `end - begin`. The user said the data is
  hourly, but the XSD would accept daily means mixed with hourly ones in one series.
- Whether the interval is closed or half-open is unstated. **Assumption:**
  `[begin, end)`, as in EEA e-Reporting.
- `observation` is `minOccurs=0`, so a sampling point may be sent with no
  data. That is fine, but it means "no data in this delivery", not "deleted".

### Q10 Station classification (Low)
`traffic | industrial | background` matches the EEA station type. The EEA
*area* classification (urban/suburban/rural) is missing, and it is usually
needed to interpret background stations. The enum is closed, so adding a value
is a breaking change for consumers who validate strictly.

### Q11 Operator (Low)
Free text, optional. Good enough for display. For filtering, an operator code
would be better.

### Q12 Payload shape and volume (Medium)
About 400 stations × 6 pollutants × 24 h = **57,600 observations/day**,
about **21 million/year**. In 2.1 XML, one observation is about 230 bytes, so a full day
in one document is about 13 MB uncompressed (about 2,400 observations, about 0.5 MB, for
an hourly delivery). That is fine for file exchange, but it is the wrong shape for a REST read API.
See design note D1.

### Q13 No delivery metadata (Medium)
`ObservationCollection` contains only stations. There is no sender, creation
time, reporting period, sequence number, or flag for initial vs. correction
delivery. You cannot tell which of two files that overlap in time is newer,
except by arrival time. Track this outside the payload (ingest envelope /
HTTP headers) until a future version adds it.

### Q14 Version in the namespace (Medium)
`targetNamespace="http://example.org/airquality/2.1"`. Every version change,
even an additive 2.2, changes the namespace of every element, so all XPath and
XML bindings on both sides break. If the partners plan more 2.x versions, suggest
a namespace per major version (`.../airquality/2`) and use the `version`
attribute for the minor version.

### Q15 `xs:double` special values (Medium)
`xs:double` accepts `NaN`, `INF`, `-INF`. JSON numbers cannot represent them,
and they are not sensible measurement values. The converter rejects them
(test case). A nil value with a negative validity is the correct way to send "no value".

### Q16 Naming (Low)
The element `stationType` has type `StationKindType`, and `StationType` is
the complex type of the station. This is easy to confuse. In the model the enum is
`StationKind`. The XML names are unchanged.

## Design notes

### D1 Resource model for the REST API
Use `ObservationCollection` (nested) only as the **bulk ingest** format
(`POST /deliveries`, accepting XML 2.1 or the equivalent JSON). For reads,
expose the same canonical classes as separate resources so that clients do not
have to fetch station documents that contain millions of observations:

- `GET /stations`, `GET /stations/{stationCode}`: Station without `samplingPoints[].observations`
- `GET /stations/{stationCode}/sampling-points`
- `GET /observations?station=…&pollutant=…&from=…&to=…&cursor=…`: flat,
  paginated rows (Observation plus `samplingPointId`, `stationCode`, `pollutant`, `unit`)

The `$defs` in the JSON Schema (`Station`, `Position`, `SamplingPoint`,
`Observation`) can be `$ref`'d from an OpenAPI document for these endpoints.
The flat observation row and the "station without observations" view are
projections of the canonical model. I did not add them to the schema because
they depend on endpoint decisions you have not made yet. They are the natural next step.

Storage: key observations by (sampling point, `begin`). At about 21 M rows/year,
partition by month (or use a time-series store).

### D2 Strictness policy
The generated XSD is exactly 2.1. The tests check this: it is structurally identical apart from
documentation, and it accepts and rejects the same documents in all test cases. The JSON Schema is stricter in
the places marked *JSON-only* (Q3, Q3b, Q5, Q6, Q15). The ingest path is
therefore: validate XML against 2.1, convert, validate against the JSON Schema,
and apply the business rules from Q2, Q7, Q8 and Q9. A rejection at step 3 means a 2.1-valid
document has a problem we flagged above.

### D3 Proposals for a future partner schema version (not applied)
CRS and units stated explicitly; code-list URIs for pollutant, unit and flags;
`xs:key` on `stationCode` and `(pollutant)` per station; `xs:unique` on
`begin` per sampling point; required UTC offset (pattern facet); a delivery
header (Q13); a namespace per major version (Q14); a single representation for
"unknown altitude".
