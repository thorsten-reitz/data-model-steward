# Exports

Exports are derived from `model.yaml` and written to `exports/<version>/`. Generate
them with `scripts/dmtool.py export` where supported, so the same model always gives the
same output. Each export has mapping choices; the defaults are listed below. Confirm the
choices that matter for the user's usage, log them in `decisions.md`, and record them
under `model.exportOptions` so later regenerations make the same choices.

## Contents
1. General mapping decisions
2. JSON Schema (script-supported)
3. XML Schema (script-supported)
4. PostgreSQL DDL (script-supported)
5. Other targets (written by you, following the same rules)
6. Checking an export

## 1. General mapping decisions

| decision | options | default |
|----------|---------|---------|
| inheritance | one table/type per class (joined) · one per concrete class · single table with discriminator | joined (SQL), type extension (XSD), `allOf` (JSON) |
| composition | nested in parent document · separate object with reference | nested (XSD/JSON), child table with FK + `ON DELETE CASCADE` (SQL) |
| reference | ID value · URI/href · embedded copy | ID value (JSON), element with `href` attribute (XSD), FK (SQL) |
| closed enumeration | enum type · lookup table · check constraint | `enum` (JSON/XSD), PostgreSQL `ENUM` type |
| extensible enumeration | free string + documented list · lookup table · URI to code list register | open string (JSON/XSD), lookup table (SQL) |
| multi-valued simple attribute | array · child table · array column | array (JSON), repeated element (XSD), child table (SQL) |
| datatype value | nested object · flattened columns · `jsonb` | nested (JSON/XSD), flattened columns, child table if multi-valued (SQL) |
| geometry | GeoJSON · GML · WKT · PostGIS | GeoJSON (JSON), placeholder `xs:anyType` + note to import GML (XSD), PostGIS `geometry(Type, SRID)` (SQL) |

Naming: canonical names are transliterated to ASCII (ä→ae, ß→ss …) and converted per
target (snake_case in SQL; otherwise unchanged in JSON/XSD). To override, set
`names: {json|xsd|postgres: …}` on the element (model-format.md §12).

Languages: `dmtool.py export … --lang de` picks the language of descriptions, titles and
comments; the default is the first documentation language. JSON Schema and XSD also
carry the other languages (see below). `--format all -o <dir>` writes every target in
`model.targets` plus `diagram.mmd`.

Existing wire formats: when the model must reproduce an existing XSD or JSON format, use
`names` for deviating names, `xml.attribute`/`xml.type` for XML attributes such as
`xs:ID`, and `codeType: integer` for numeric code lists. Then check compatibility with lxml (§6):
- Test a typical valid document **and edge cases**: nil and omitted optional values,
  timestamps without a time zone, unknown code values, extreme or out-of-range numbers,
  repeated elements at their bounds. One sample is not enough.
- Every document the original accepts must also validate against the generated schema,
  and vice versa where intended.
- Any deliberate tightening, such as coordinate ranges or required time zones, breaks
  existing senders. Record it as a decision, tell the user, or keep it out of the
  compatible schema and enforce it elsewhere, e.g. in a stricter API schema.

## 2. JSON Schema (draft 2020-12)

`dmtool.py export --format jsonschema`

- One `$defs` entry per class, datatype and enumeration. `deprecated: true` for deprecated
  elements; `description` from the model.
- Root: if `model.exportOptions.jsonschema.root` names a class, the root `$ref`s it;
  otherwise `anyOf` over all concrete, non-part classes.
- Subclasses: `allOf: [{$ref: parent}]` plus own properties, with
  `unevaluatedProperties: false` so closed content works across inheritance. Set
  `exportOptions.jsonschema.closed: false` for open content (friendlier to evolution,
  see versioning reference).
- Lower bound ≥ 1 and not voidable → `required`. Voidable → type allows `null`.
  Upper bound > 1 → `array` with `minItems`/`maxItems`.
- References → the target's identifier value (`format: uuid`, `uri`, or string).
- `history` adds `versionId`, `validFrom`, `validTo` (and `recordedAt` for bitemporal).
- Constraints that JSON Schema can't express (cross-field rules) go into `$comment`.
- `label` → `title`, `description` → `description`, both in the export language. Other
  languages go in `x-i18n: {de: {title, description}}`. Enumeration value labels go in
  `x-enumLabels: {lang: {code: label}}`.
- `codeType: integer` → `type: integer` with an integer `enum`.
- Reused vocabularies: `x-vocabulary` (uri, name, publisher, version, retrieved, licence)
  and `x-enumUris: {code: uri}`. With `represent: uri`, the enum values are the URIs
  (`format: uri`).

## 3. XML Schema (XSD 1.0)

`dmtool.py export --format xsd`

- `targetNamespace` = `model.namespace`, `elementFormDefault="qualified"`.
- Each class → `complexType <Name>Type` + global element `<Name>` (not for abstract
  classes, which get `abstract="true"`). Subclasses use `xs:extension`.
- Attributes → child elements in a `xs:sequence` (order = model order, then association
  roles); multiplicity → `minOccurs`/`maxOccurs`; voidable → `nillable="true"`.
- `xml: {attribute: true}` → `xs:attribute` (after the sequence, `use="required"` for lower
  bound 1). `xml: {type: "xs:ID"}` sets the literal XSD type. `xml.typeName` and
  `xml.globalElement` on classes control type names and global elements.
- The identifier stays an element by default. Use `xml.attribute` with `xs:ID` only to
  match an existing format: `xs:ID` values are only unique within one document and
  cannot start with a digit (e.g. UUIDs).
- References → element of type `ReferenceType` with attribute `href` (URI or ID).
- Closed enumeration → `xs:simpleType` with `xs:enumeration` (base `xs:int` for
  `codeType: integer`); extensible → unrestricted base type with documentation listing
  known values.
- Documentation: one `xs:documentation xml:lang="…"` per documentation language, on types,
  elements, attributes and enumeration values (labels).
- Reused vocabularies: the code list's documentation names the source, version and
  retrieval date. With `represent: uri`, the base is `xs:anyURI` and the enumeration
  values are the value URIs.
- Geometry → `xs:anyType` with an annotation. For real use, import GML
  (`gml:PointPropertyType`, etc.) — this is a decision to confirm and do by hand.
- Constraints that XSD 1.0 can't express → `xs:annotation/xs:documentation`
  (Schematron is an option if validation is needed).

## 4. PostgreSQL DDL

`dmtool.py export --format postgres`

- Everything in a schema named after the model (snake_case). Tables first, then foreign
  keys via `ALTER TABLE`, then indexes and comments — so creation order never matters.
- Primary key: the identifier attribute; `uuid` strategy → `DEFAULT gen_random_uuid()`;
  no identifier → `id bigint GENERATED ALWAYS AS IDENTITY`.
- Inheritance (joined): subclass table has PK = FK to parent table PK.
- Association mapping: `to` upper bound 1 → FK column `<role>_id` on the `from` table;
  `from` upper bound 1 and `to` many → FK on the `to` table; many-to-many → join table
  `<from>_<role>`. Composition → FK on the part table with `ON DELETE CASCADE`.
- Every FK column gets an index. `unique` → `UNIQUE`.
- `history.mode` `audit`/`versioned`/`bitemporal` → `<table>_history` table (`history_id`,
  `operation`, `recorded_at`, `recorded_by`, and the row as `row_data jsonb`); `validTime` →
  `valid_from`/`valid_to` columns on the main table; `deletion: logical` → `deleted_at`.
  Triggers that fill the history table are left to the implementation (comment emitted) —
  offer to write them.
- Closed enumeration → `ENUM` type (labels in its comment); `codeType: integer` →
  `smallint`/`integer` column with `CHECK (col IN (…))`; extensible → lookup table
  (`code`, `label` in the export language, `description`, `deprecated`) with a FK.
- Reused vocabularies always become a lookup table, even when closed. The table gets an
  extra `uri` column, and its comment names the source. Enum types can't hold value URIs,
  and PostgreSQL limits enum labels to 63 bytes.
- `COMMENT ON` texts are in the export language (`--lang`).
- `geometry` → PostGIS `geometry(<Type>, <SRID>)` and `CREATE EXTENSION IF NOT EXISTS postgis`.
- Use `nfr` for physical tuning *after* the generated DDL: e.g. GiST index for spatial
  access paths, partitioning for > ~100 M rows or time-based retention, BRIN for
  append-only timestamps. Put these in a separate `tuning.sql` so regeneration doesn't lose them.
- For a new version of a released model, `dmtool.py migrate <old.yaml> <new.yaml>` writes
  the migration script; `release` puts it in `exports/<version>/migrate_<old>_to_<new>.sql`.
  It compares the DDL generated for both versions. The script contains:
  - **automatic statements:** new tables, columns, foreign keys, indexes, comments and
    lookup values; `ALTER TYPE … ADD VALUE` before the transaction; relaxed NOT NULL;
    CHECK and UNIQUE changes;
  - **`REVIEW` statements:** type changes and new NOT NULLs, which may fail on existing data;
  - **manual steps** at the end: backfills for new mandatory columns, dropped columns and
    tables, removed enum values, renames (`RENAME COLUMN` instead of add + drop).

  Check it with the user and adapt it, e.g. fill new mandatory columns in the TODO steps.
  Hand-tuning (`tuning.sql`) is not covered.

`dmtool.py release` regenerates all targets into `exports/<version>/` in the default
language. For another language, run `export --lang` into the same folder with a suffix,
e.g. `schema.de.sql`.

## Review page (`dmtool.py docs`)

`docs` writes a Markdown data dictionary for people who shouldn't need to read YAML. It
renders on GitHub, Mermaid diagram included, and diffs well between versions. It
contains:
- an overview;
- the review status: elements still `proposed`, missing translations, and the questions
  and assumptions from `open-questions.md`;
- the diagram;
- per object type: the facts, an attribute table and the associations;
- value types, code lists (with source and value URIs) and rules.

Headings are translated for en/de, with English for other languages. `--lang all -o <dir>`
writes one file per documentation language. `release` adds `model.md` (or `model.<lang>.md`
per language) to `exports/<version>/`.

## 5. Other targets (not in the script — write them following the rules above)

- **OWL / RDFS + SHACL** (purpose `ontology`): class → `owl:Class`; attribute with
  simple type → `owl:DatatypeProperty` (XSD datatypes); association → `owl:ObjectProperty`
  with `rdfs:domain`/`rdfs:range`; enumeration → SKOS `ConceptScheme` + `Concept`s;
  datatype → class without IRI identity (blank nodes) or structured literal.
  Multiplicities and closed-world constraints belong in SHACL shapes (`sh:minCount`,
  `sh:maxCount`, `sh:datatype`, `sh:class`, `sh:in`), not OWL restrictions, unless reasoning
  is a goal. IRIs: `model.namespace` + `#`/`/` + name; decide hash vs. slash with the user.
- **OpenAPI 3.1**: reuse the JSON Schema export under `components/schemas`.
- **Avro / Protobuf** (event streams): records/messages per class; never reuse Protobuf
  field numbers; optional = union with null (Avro) or `optional` (proto3). Their own
  compatibility rules (schema registry modes) should be stated alongside ours.
- **GraphQL SDL**: types per class, enums, non-null `!` for lower bound ≥ 1, lists for
  upper bound > 1, associations as fields in both directions if navigable both ways.
- **Documentation**: a Markdown/HTML data dictionary (class, attribute, type, multiplicity,
  definition, source) is often what business stakeholders actually read — offer it.

## 6. Checking an export

- JSON Schema: validate the schema itself and, if available, an example instance
  (`python -c "import jsonschema"`…); XSD: `xmllint --noout --schema`; PostgreSQL: run the
  DDL against a scratch database if one is available (`psql` / Docker). Report what you
  could and could not check.
- Create one small example instance per export from realistic (non-personal) values;
  examples catch modelling mistakes that schemas hide.
