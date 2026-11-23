# Canonical model format (`model.yaml`)

The canonical model is a YAML file with five top-level sections. It is deliberately
close to a UML class model (classes, data types, enumerations, associations) because
that maps cleanly to relational, document/tree and graph targets alike.

`scripts/dmtool.py validate` checks this format. `assets/model-template.yaml` is a
complete worked example.

## Contents
1. `model` header
2. Neutral data types
3. Multiplicities
4. `enumerations`
5. `datatypes`
6. `classes` and attributes
7. `associations`
8. `constraints`
9. Provenance and lifecycle fields (common to all elements)
10. Naming conventions

## 1. `model` header

```yaml
model:
  name: PermitRegistry            # UpperCamelCase identifier, used for namespaces/schema names
  title: Permit Registry Model
  description: Permits issued by local authorities and their conditions.
  namespace: https://example.org/models/permit-registry   # base URI, also XSD targetNamespace
  prefix: pr                      # short prefix for XML/RDF
  version: 0.1.0                  # semantic version of the MODEL (not of the data)
  status: draft                   # draft | released
  purposes: [persistence, exchange]   # persistence | exchange | api | analytics | ontology | codegen
  targets: [postgres, jsonschema, xsd]
  conventions:
    language: en
  standards: []                   # reference models / standards the model aligns with
  sources: [S1]
```

## 2. Neutral data types

| type       | meaning                                         | useful constraints |
|------------|-------------------------------------------------|--------------------|
| `string`   | short text, single line                         | `maxLength`, `minLength`, `pattern` |
| `text`     | long / multi-line text                          | `maxLength` |
| `boolean`  | true/false                                      | |
| `integer`  | 32-bit-safe integer                             | `min`, `max` |
| `long`     | 64-bit integer                                  | `min`, `max` |
| `decimal`  | exact decimal (money, measurements)             | `precision`, `scale`, `min`, `max`, `unit` |
| `float`    | approximate floating point                      | `min`, `max`, `unit` |
| `date`     | calendar date                                   | |
| `dateTime` | timestamp **with** time zone/offset             | |
| `time`     | time of day                                     | |
| `duration` | ISO 8601 duration                               | |
| `uri`      | URI/IRI                                         | |
| `uuid`     | UUID                                            | |
| `binary`   | opaque bytes (prefer a `uri` to external content for large blobs) | `maxLength` (bytes) |
| `geometry` | spatial geometry                                | `geometryType` (Point, LineString, Polygon, MultiPoint, MultiLineString, MultiPolygon, Geometry), `crs` (e.g. `EPSG:4326`), `dimension` |

A type can also be the name of an enumeration or datatype defined in the model.
Classes are never used as attribute types — relate classes through `associations`.
Rationale: it forces an explicit decision on identity, ownership (reference vs.
composition) and multiplicity on *both* ends.

## 3. Multiplicities

Quoted strings: `"1"`, `"0..1"`, `"0..*"`, `"1..*"`, `"n..m"` (e.g. `"2..5"`). Default `"1"`.

## 4. `enumerations` (code lists)

```yaml
enumerations:
  PermitStatus:
    description: Lifecycle status of a permit.
    extensible: false        # false = closed enum; true = open code list (values may be added without a model release)
    authority: null          # who maintains the list, or URI of an external code list register
    values:
      - code: applied
        label: Applied
        description: Application received, not yet decided.
      - code: granted
      - code: revoked
        deprecated: {since: 1.2.0, reason: "Replaced by 'withdrawn'", replacedBy: withdrawn}
```

## 5. `datatypes` (structured values without identity)

Use for values compared by content, not by identity (address, money amount, measure, period).

```yaml
datatypes:
  Address:
    description: Postal address.
    attributes:
      street:     {type: string, multiplicity: "0..1", constraints: {maxLength: 200}}
      postalCode: {type: string, constraints: {maxLength: 10}}
      city:       {type: string, constraints: {maxLength: 100}}
```

## 6. `classes` and attributes

```yaml
classes:
  Permit:
    description: Official authorisation granted to an applicant for an activity at a site.
    abstract: false
    extends: null                    # name of the parent class (single inheritance)
    identifier:
      attribute: permitId            # attribute that identifies instances
      strategy: uuid                 # uuid | natural | sequence | uri
      external: true                 # identifier is shared with other systems → must be stable
    history:                         # versioning / historisation of the DATA
      mode: versioned                # none | audit | versioned | bitemporal
      validTime: true                # track when facts are true in reality
      transactionTime: true          # track when the system recorded them
      deletion: logical              # logical | physical
      lifecycleAttribute: status     # optional: attribute holding the lifecycle state
    nfr:
      volume: 2000000                # expected number of instances now
      growth: 200000/year
      readWriteRatio: 50:1
      accessPaths: ["by permitId", "by applicant", "by site within bounding box"]
      latency: "p95 < 200 ms for lookups by id"
      classification: personal       # public | internal | confidential | personal
      retention: 10 years after expiry
    attributes:
      permitId:
        type: uuid
        description: Stable identifier of the permit.
        unique: true
      reference:
        type: string
        description: Human-readable file number used by the authority.
        constraints: {maxLength: 40, pattern: "^[A-Z]{2}-[0-9]{4}-[0-9]+$"}
      status: {type: PermitStatus}
      validUntil:
        type: date
        multiplicity: "0..1"
        voidable: true               # "unknown" is a legitimate value, distinct from "not applicable"
      siteLocation:
        type: geometry
        constraints: {geometryType: Polygon, crs: "EPSG:4326"}
      area:
        type: decimal
        derived: true                # computed from siteLocation, not stored at the source
        constraints: {precision: 12, scale: 2, unit: m2}
```

Attribute fields: `type` (required), `description`, `multiplicity` (default `"1"`),
`constraints`, `unique`, `voidable`, `derived`, `ordered` (for multi-valued), `default`,
plus provenance/lifecycle fields.

## 7. `associations`

Each association has two ends. Read `to.role` as "the property on `from` that points to
`to`", and `to.multiplicity` as "how many `to` objects one `from` object has" (UML convention).

```yaml
associations:
  - name: PermitIssuedBy
    description: The authority that issued the permit.
    kind: reference                  # reference | aggregation | composition
    from: {class: Permit,    role: permits, multiplicity: "0..*"}
    to:   {class: Authority, role: issuer,  multiplicity: "1"}
    navigable: from              # from (only from→to) | both
  - name: PermitConditions
    kind: composition                # `from` is the whole, `to` the part; parts live and die with the whole
    from: {class: Permit,          role: permit,     multiplicity: "1"}
    to:   {class: PermitCondition, role: conditions, multiplicity: "0..*"}
    ordered: true
```

If an association carries its own attributes (e.g. role of a person in an application
with a start date), model it as a class with two associations (association class).

## 8. `constraints`

Rules that span attributes or objects:

```yaml
constraints:
  - id: C-001
    appliesTo: Permit
    description: validUntil must be after the decision date.
    expression: "validUntil > decisionDate"   # informal; exporters emit it as documentation unless they can translate it
    sources: [S1]
```

## 9. Provenance and lifecycle fields

Allowed on classes, datatypes, enumerations, enum values, attributes, associations, constraints:

| field        | meaning |
|--------------|---------|
| `sources`    | list of source IDs from `sources.md` (e.g. `[S1, S3]`), or `interview:<date>` |
| `decisions`  | list of decision IDs from `decisions.md` |
| `since`      | model version in which the element was introduced |
| `deprecated` | `{since, reason, replacedBy}` — still present and valid, but scheduled for removal |
| `notes`      | free-text modelling notes not meant for exports |
| `status`     | `proposed` while not yet confirmed by the user; remove once confirmed |

`status: proposed` is useful while drafting: the validator lists all proposed elements so
nothing unconfirmed slips into a release.

## 10. Naming conventions

- Canonical names: classes, datatypes, enumerations in `UpperCamelCase`; attributes and
  roles in `lowerCamelCase`; enum codes as agreed with the user (often `lowerCamelCase` or
  stable codes from an external list — never change a code once released).
- Exporters convert case per target (e.g. `snake_case` for PostgreSQL); don't encode
  target-specific names in the canonical model. If a target needs a specific name that
  cannot be derived, add `names: {postgres: permit_tbl}` on the element.
- Use singular nouns for classes; plural role names for multi-valued ends.
