# Versioning, historisation and compatibility

Two different things are both called "versioning" — keep them apart when talking to the user:

- **Data versioning / historisation**: how instances change over time (Part A).
- **Model versioning**: how the schema itself evolves across releases (Part B).

## Part A — Historisation of data

### Questions to settle per class
1. Must old states be retrievable? For whom (users, auditors, analytics)?
2. Which time: *valid time* (when the fact is true in the real world, can be in the past
   or future, can be corrected) and/or *transaction time* (when the system recorded it,
   never changes)? Both = bitemporal.
3. Granularity: whole object versions, or per-attribute change tracking?
4. Deletions: physical, or logical (marked as deleted/retired, still retrievable)?
5. Retention: how long are old versions kept; are there legal deletion obligations (GDPR)?
6. Do references point to "the object" (always current version) or to "a specific version"?

### Modes (`history.mode`)

| mode         | meaning | typical use |
|--------------|---------|-------------|
| `none`       | only current state | reference data, caches |
| `audit`      | who changed what when, for accountability; not queried as business data | most operational data |
| `versioned`  | each change creates a new version with `versionId`, `validFrom/validTo` or `beginLifespan/endLifespan` | registers, master data, exchange with change history |
| `bitemporal` | valid time and transaction time | legal registers, corrections of the past, "as known on date X" reporting |

### Mapping patterns

- **Neutral model**: don't add version columns as ordinary attributes; declare `history`
  and let exporters add the technical fields. Exception: when lifecycle info is business
  content in an exchange standard (e.g. `beginLifespanVersion`), model it explicitly and
  reference the decision.
- **PostgreSQL**: current table + `<table>_history` table populated by trigger
  (`audit`/`versioned`); `valid_from`/`valid_to` (or a `tstzrange` with an exclusion
  constraint against overlaps) for valid time; `recorded_from`/`recorded_to` for
  transaction time. References from other tables point to the stable identifier, not the
  version row.
- **Exchange (XSD/JSON)**: add `versionId`, `validFrom`, `validTo` (and
  `recordedAt` for bitemporal) to the exchanged object; decide whether a document carries
  only current versions or full histories.
- **Ontology**: versions as separate resources linked by `prov:wasRevisionOf`, or named graphs per version.

## Part B — Model versioning

### Semantic versioning of the model
- `MAJOR` — breaking change for existing data or existing consumers of a declared usage.
- `MINOR` — backwards-compatible additions, deprecations, relaxations.
- `PATCH` — documentation, descriptions, labels, examples; no structural change.
- `0.x.y` — pre-release; breaking changes allowed in minor bumps, but still list them.

The first release that others build on should be `1.0.0`. Snapshots of each release
live in `releases/<version>/model.yaml` and are never edited.

### Two perspectives on "breaking"

Judge every change from both perspectives, and weigh them by the model's `purposes`:

1. **Existing data**: does data valid under the old version stay valid under the new one?
   (Most important for persistence: otherwise a data migration is needed.)
2. **Existing consumers**: does software written against the old version still
   understand data produced under the new one? (Most important for exchange and APIs.)

How much (2) matters depends on how consumers validate, recorded in
`model.compatibility.consumers`:

- **strict**: consumers validate against the released schema, e.g. JSON Schema with
  `unevaluatedProperties: false`, an XSD sequence, or a closed `enum`. Any addition they
  don't know about is rejected, even an optional field. This is the default when the
  model's purposes include `exchange` or `api`.
- **tolerant**: consumers ignore unknown fields and values (the "must-ignore" rule). This
  is the default otherwise.

### Change classification (what `dmtool.py diff` implements)

`risk` below means the change breaks strict consumers and is safe for tolerant ones. `diff`
reports risk changes as follows; you can override the mode with `--consumers`:

- strict mode: `CONSUMERS`, major;
- strict mode with `compatibility.projection: true`: `CONSUMERS`, minor, because old
  consumers keep receiving their version;
- tolerant mode: `compatible`, minor.

| change | existing data | existing consumers | bump |
|--------|---------------|--------------------|------|
| add class / datatype / enumeration | ok | ok | minor |
| add optional attribute or association end | ok | risk: strict validators reject unknown elements | strict: major · tolerant: minor |
| add mandatory attribute (lower bound ≥ 1) | **breaks** (old data lacks it) | **breaks** | major |
| remove class / attribute / association / enum value | **breaks** | **breaks** | major |
| rename anything (incl. `names`/`xml` overrides) | **breaks** | **breaks** | major |
| raise lower bound (0..1 → 1) | **breaks** | ok | major |
| lower lower bound (1 → 0..1) | ok | risk: consumers expect the value | strict: major · tolerant: minor |
| lower upper bound (`*` → 1, 5 → 3) | **breaks** | ok | major |
| raise upper bound from 1 to >1 | ok | **breaks** (value becomes list; column becomes table) | major |
| raise upper bound >1 (3 → 5) | ok | risk | strict: major · tolerant: minor |
| widen type (integer→long→decimal, string→text) | ok | risk | strict: major · tolerant: minor |
| narrow or change type otherwise | **breaks** | **breaks** | major |
| relax constraint (longer maxLength, wider range, pattern removed) | ok | risk | strict: major · tolerant: minor |
| tighten constraint | **breaks** | ok | major |
| add enforced rule (`constraints`) for all data | may break | ok | major |
| add rule with `scope: new` or `enforcement: warning`/`documented` | ok | ok | minor |
| add value to closed enum | ok | risk | strict: major · tolerant: minor |
| add value to extensible enum | ok | ok | minor (no model change needed if values are managed externally) |
| make enum closed | may break | ok | major |
| `voidable` false → true | ok | risk | strict: major · tolerant: minor |
| `voidable` true → false | **breaks** | ok | major |
| change `extends`, `abstract`, identifier, association kind, or enum `codeType` | **breaks** | **breaks** | major |
| mark deprecated | ok | ok | minor |
| description / label / notes / translations | ok | ok | patch |

### Strict consumers: what to offer instead of a major release

With strict consumers, even an optional addition breaks them. Tell the user, then offer:

1. **A projection for old consumers.** The exchange interface sends each partner documents
   in the version they implemented, leaving out elements added later. That's always
   possible when additions are optional. Record which partner is on which version. Once
   the interface does this, set `compatibility.projection: true`. Additions then count
   as minor versions, and the CHANGELOG lists what each projection must drop.
2. **Derive instead of store.** For example, compute "expired" from `validUntil` instead
   of adding a value to a closed status list.
3. **Agree on open content for the future.** In the next major version, switch to
   tolerant consumers: `exportOptions.jsonschema.closed: false` and the must-ignore rule
   in the interface contract. After that, optional additions stop being breaking.
4. **A major version**, bundling several breaking changes, with a migration period.

### Avoiding breaking changes

| instead of … | prefer … |
|--------------|----------|
| renaming an attribute | add the new one, deprecate the old one with `replacedBy`, remove in the next major |
| adding a mandatory attribute | add it optional (or with a `default`), make it mandatory in the next major |
| changing a type | add a new attribute with the new type; deprecate the old |
| single value → list | add a new multi-valued attribute; deprecate the single one |
| splitting a class | introduce the new classes alongside, link them, deprecate the old |
| removing an enum value | deprecate the value; consumers keep accepting it |
| tightening a constraint | add it as a *warning-level* rule first (documented, not enforced), enforce in next major |
| closed enum that keeps growing | make it `extensible: true` with a managed code list register |

Also design for evolution from the start: open content / extension points in exchange
formats where partners need them, `extensible` code lists where values change often,
surrogate identifiers instead of meaningful keys.

### When a breaking change is really necessary
1. Explain to the user: what breaks, for whom, the non-breaking alternative and its cost.
2. Get an explicit decision; log it in `decisions.md`.
3. Bundle breaking changes into one major release rather than spreading them out.
4. Write migration guidance into the CHANGELOG: SQL migration steps, transformation rules
   old → new for exchange partners (ideally a mapping table per changed element), and a
   deprecation/support timeline for the old version.
5. Remove elements deprecated in earlier versions in the same major release if the user agrees.

### CHANGELOG entry format

```markdown
## 1.1.0 — 2026-11-23
Sources: S4 (amendment request 2026-11)
### Added
- `Permit.renewalOf` (0..1 reference to Permit) — S4 §2, D-014
### Deprecated
- `Permit.oldReference` — replaced by `Permit.reference`, removal planned for 2.0.0
### Compatibility
- Non-breaking. Risk for strict XML consumers: new optional element `renewalOf`.
```
