# Ingesting sources

Goal of ingestion: a list of *candidates* with evidence, not a finished model. Every
candidate carries the source ID and a location (section, page, line, element path) so the
user can check it and so later amendments can trace back.

## Register first

Add each input to `sources.md` before extracting from it:

```markdown
| ID | Title | Location | Version/date | Kind | Covers | Authority |
|----|-------|----------|--------------|------|--------|-----------|
| S1 | Permit process description | docs/process.pdf | 2026-03 | prose/use cases | application → decision flow | normative |
| S2 | Legacy permit DB | legacy/schema.sql | prod dump 2026-10 | DDL | current persistence | informative |
```

*Authority* matters when sources conflict: a regulation or a standard the model must
conform to (normative) wins over a legacy system (informative); ask the user if unclear.

## Candidate list format

Keep it in the conversation (or a scratch file for large inputs) in this shape:

```
Classes:     Permit (S1 §2.1, S2 table permit) — "authorisation for an activity"
Attributes:  Permit.validUntil : date [0..1] (S2 permit.valid_to, nullable)
Assocs:      Permit → Authority, many-to-one (S1 §2.3 "issued by the competent authority")
Code lists:  PermitStatus {applied, granted, refused, revoked} (S2 CHECK constraint)
Rules:       "A permit expires at the latest 10 years after the decision" (S1 §4)
Volumes:     ~2M permits, 200k/year (S1 annex B)
Conflicts:   S1 says one applicant per permit; S2 has permit_applicant join table → Q-003
Gaps:        no information on history requirements → ask in Phase 4
```

## By input type

### Prose, requirements, use cases, user stories
- Nouns that are identified, counted, or have a lifecycle → class candidates. Nouns that
  only describe something → attributes or datatypes. Fixed lists of words ("can be
  urgent, normal or low") → enumerations.
- Verbs between nouns → associations; look for quantifiers ("each", "one or more", "at most")
  to derive multiplicities. Where none are given, mark the multiplicity as assumed.
- Use case steps reveal access paths ("the clerk searches permits by applicant name")
  → record as `nfr.accessPaths`. Data flows reveal producers/consumers and exchange
  boundaries → candidate exchange root elements.
- Rules with "must", "may not", "at the latest" → `constraints`.
- Watch for synonyms (licence/permit/authorisation) and homonyms ("site" meaning both
  location and organisation unit); record them in `glossary.md`.

### ER and UML diagrams (images, PlantUML, Mermaid, draw.io, XMI)
- Entities/classes → classes; attributes keep their types but map them to neutral types.
- Crow's-foot or UML multiplicities → association ends. ER foreign keys usually mean a
  reference association from the FK-holding entity, multiplicity `0..*`/`1`.
- UML composition (filled diamond) → `kind: composition`; aggregation (hollow) → treat as
  reference unless the user says otherwise (its semantics are vague).
- Stereotypes (`<<featureType>>`, `<<dataType>>`, `<<codeList>>`, `<<enumeration>>`, `<<union>>`)
  map to class / datatype / extensible enumeration / closed enumeration; a `<<union>>`
  usually becomes a datatype with mutually exclusive `0..1` attributes plus a constraint.
- For images, transcribe what you see and say explicitly which parts were unreadable.
- XMI: parse with a script rather than reading raw XML by eye if it is large.

### XML Schema (XSD)
- Global `complexType`s with an identifier attribute (`gml:id`, `id`, a key) → classes;
  without identity → datatypes. `xs:extension` → `extends`.
- `minOccurs`/`maxOccurs` → multiplicity; `nillable="true"` → `voidable: true`.
- `xs:enumeration` facets → closed enumeration; string elements documented as code lists
  or with `codeSpace` → extensible enumeration.
- Nested complex elements are compositions; elements with `xlink:href` / `ref`-style
  attributes, `xs:keyref` or `IDREF` are references.
- `xs:choice` → mutually exclusive attributes plus a constraint, or a datatype
  hierarchy; note the choice explicitly, it does not map 1:1 to all targets.
- If the model must stay compatible with the XSD, reproduce it:
  - keep its `targetNamespace` as `model.namespace`;
  - map deviating element names with `names: {xsd: …}`;
  - map XML attributes (e.g. `@id` of type `xs:ID`) with `xml: {attribute: true, type: "xs:ID"}`;
  - map numeric codes with an enumeration `codeType: integer`, or keep the plain type with
    `xml.type` if the XSD doesn't restrict it.

  Then check that a sample instance is valid against both the original and the generated XSD.
- `xs:documentation xml:lang` annotations in several languages map to multilingual
  `description`s; declare those languages in `model.languages.documentation`.

### JSON Schema / OpenAPI
- `$defs`/`components.schemas` objects → classes or datatypes (classes if they carry an
  `id` and are referenced from several places; datatypes if only embedded).
- `required` → lower bound 1; `type: [x, "null"]` → voidable; arrays → upper bound `*`
  (`minItems`/`maxItems` → bounds).
- `enum` → closed enumeration; `allOf` with a single `$ref` + properties → `extends`.
- `oneOf`/`anyOf` with a discriminator → subclass hierarchy; otherwise a constraint.
- Properties holding an ID or URI of another object → reference association.

### SQL DDL / database dumps
- Tables → classes, except pure join tables (two FKs, composite PK, no other columns) →
  many-to-many association; join tables with extra columns → association class.
- FKs → reference associations (`ON DELETE CASCADE` hints at composition).
- `NOT NULL` → lower bound 1; `UNIQUE` → `unique`; `CHECK (x IN (...))` and lookup tables
  → enumerations; `varchar(n)` → `maxLength: n`; `numeric(p,s)` → precision/scale.
- Technical columns (`created_at`, `updated_by`, `valid_from`, `version`, `deleted`)
  are evidence for history requirements — move them out of the attributes and into
  `history`, and confirm with the user.
- Row counts and index definitions → `nfr.volume` and `nfr.accessPaths`.
- Legacy schemas often contain denormalisations and workarounds. Don't copy them into
  the neutral model blindly; note them and ask.

### Sample data (CSV, JSON, XML instances)
- Useful for checking multiplicities, value ranges, actual code values, null rates and
  typical sizes. Report observations ("validUntil empty in 38 % of rows") rather than
  converting them straight into constraints — samples can be unrepresentative.
- Never copy personal data from samples into the model, examples or exports.

## After extraction

1. Merge candidates across sources; align names with the glossary.
2. List conflicts and gaps as `Q-…` entries in `open-questions.md`.
3. Present the ingestion summary to the user, then continue with the next phase.
