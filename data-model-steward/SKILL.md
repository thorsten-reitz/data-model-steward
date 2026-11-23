---
name: data-model-steward
description: Interactively design, document, version and maintain implementation-neutral data models, and export them as XML Schema, JSON Schema, PostgreSQL DDL, Mermaid diagrams and more. Use this skill whenever the user wants to create a data model, domain model, information model, schema, ER/UML class model or ontology from requirements, use cases, data-flow descriptions, existing schemas (XSD, JSON Schema, DDL, XMI, OpenAPI) or other documentation; whenever they want to amend, extend, review or release an existing model (especially one kept in a `datamodel/` folder with a `model.yaml`); and whenever they ask whether a schema change is breaking or how to evolve a schema compatibly — even if they don't say "data model" explicitly (e.g. "we need a schema for exchanging permit data", "add these fields from the new spec to our model", "generate the DDL for v2").
---

# Data Model Steward

You help a user build and then *maintain over time* a data model. The model lives as
files in the user's project, so later sessions (yours or someone else's) can pick it up
again. Your job is half analyst (clarify goals, find the object types, challenge vague
requirements), half librarian (keep provenance, decisions and versions in order).

Three principles drive everything below:

1. **One canonical, implementation-neutral model.** `datamodel/model.yaml` is the source
   of truth. XSD, JSON Schema, DDL and diagrams are *derived* and can be regenerated at any
   time. Never hand-edit an export and leave the canonical model behind.
2. **Everything is traceable.** Each class, attribute and association points to the
   sources (documents, interview answers) and decisions that justify it. This is what makes
   later amendments safe: when a source changes, you can find what depends on it.
3. **Released versions are a contract.** After the first release, every change is
   classified for compatibility, and breaking changes need a reason, an explicit user OK,
   and a migration note.

## The model workspace

On first use, create this structure in the user's project with
`python scripts/dmtool.py init datamodel --name <ModelName> --languages en[,de,…]`
(ask where if it's unclear; default `./datamodel/`):

```
datamodel/
├── model.yaml            # canonical model — format in references/model-format.md
├── sources.md            # register of input documents: S1, S2, … (title, path/URL, date, what it covers)
├── decisions.md          # decision log: D-001, … (context, options, choice, rationale, date)
├── open-questions.md     # unresolved questions and working assumptions (Q-001 / A-001)
├── glossary.md           # domain terms, synonyms, terms deliberately NOT used
├── CHANGELOG.md          # per version: added / changed / deprecated / removed / breaking
├── releases/<version>/model.yaml   # frozen snapshot of each released version
└── exports/<version>/…   # generated schemas, never edited by hand
```

`assets/model-template.yaml` is a complete worked example to copy patterns from. If a
`datamodel/` folder already exists, you are in **maintenance mode** — skip to "Amending an
existing model".

Use `scripts/dmtool.py` (Python 3 + PyYAML) for everything deterministic:

```
python scripts/dmtool.py init     datamodel --name PermitRegistry --languages en,de
python scripts/dmtool.py validate datamodel/model.yaml
python scripts/dmtool.py diagram  datamodel/model.yaml            # Mermaid class diagram
python scripts/dmtool.py export   datamodel/model.yaml --format jsonschema|xsd|postgres|all -o <file|dir> [--lang de]
python scripts/dmtool.py diff     datamodel/releases/1.0.0/model.yaml datamodel/model.yaml [--consumers strict|tolerant]
python scripts/dmtool.py release  datamodel [--version X.Y.Z] [--dry-run]
```

`release` does the whole release in one step. It validates (unconfirmed `proposed` elements
and missing translations are errors), works out the minimum version from the diff against
the last release, and sets `version` and `status`. It then saves the snapshot in
`releases/`, regenerates every target into `exports/<version>/` and drafts the CHANGELOG
entry. It never overwrites an existing release. Use `--dry-run` to show the user the plan first.

Run `validate` after every edit of `model.yaml`. Generating schemas with the script rather
than writing them freehand keeps exports reproducible and consistent across versions; if a
target needs something the script cannot express, generate with the script first and then
document the manual adjustment as a decision.

## Workflow for a new model

Work in phases and get a short confirmation at the end of each one. Users find it much
easier to correct a list of ten classes than a finished 40-attribute schema, and late
changes to the conceptual structure are expensive.

### Phase 0 — Ingest sources

Read everything the user provides before asking questions; don't ask what the documents
already answer. For each source: add it to `sources.md`, then extract candidates (object
types, attributes, relationships, code lists, constraints, volumes, rules) with the source
ID attached. `references/source-ingestion.md` explains how to read each kind of input
(prose, use cases, ER/UML diagrams, XSD, JSON Schema, DDL, XMI, sample data).

Produce a short **ingestion summary**: what you found, conflicts between sources, and
gaps. Conflicts become open questions, not silent choices.

### Phase 1 — Goal and usage

Clarify, in one compact round of questions (offer your best guess for each so the user can
just confirm):

- **Purpose and scope**: what problem the model solves, what is explicitly out of scope.
- **Usages** — one or more of: persistence (which DBMS?), data exchange (formats, partners,
  existing standards it must conform to), API payloads, analytics/warehouse, ontology /
  knowledge graph, code generation. Usage determines which compatibility rules matter and
  which exports are needed.
- **Stakeholders and producers/consumers** of the data.
- **Standards and reference models** to align with or reuse (e.g. domain standards,
  existing code lists). Reusing beats reinventing.
- **Languages**: the language of the identifiers (class and attribute names), and the
  documentation languages for definitions, labels and code-list labels. The default is
  the user's language for documentation, with identifiers in English unless the domain or a
  standard says otherwise. Several documentation languages are common for public-sector and
  cross-border models. Record them in `model.languages`. Identifiers may use non-ASCII
  letters (e.g. `länge`); exporters transliterate them (`laenge`), and `names` overrides
  per target are available.
- **Conventions**: case style per target, namespace/URI base.
- **How consumers validate**: do partners validate strictly against the released schema
  (closed content, closed enums)? If so, even optional additions break them. Record it in
  `model.compatibility.consumers` (`strict`/`tolerant`); `diff` and `release` use it.

Record the answers in the `model:` header of `model.yaml` and in `decisions.md`.

### Phase 2 — Conceptual model (object types and associations)

Propose the main object types with a one-sentence definition each, their associations with
multiplicities and kind (reference vs. composition), and generalisations. Show it as a
Mermaid diagram (`dmtool.py diagram`). Point out modelling choices the user should make
consciously, for example: entity vs. value type, a code list vs. a class, a relationship
that carries attributes (→ association class), inheritance vs. a type attribute.

Also settle **identity** per object type here: natural key, surrogate (UUID), external
identifier/URI, and whether identifiers must be stable across systems — this matters a
lot for exchange and ontology use.

### Phase 3 — Attributes and constraints

For each class, propose attributes with type, multiplicity, definition, and constraints
(length, range, pattern, unit, code list). Use the neutral types from
`references/model-format.md`. Explicitly ask about:

- mandatory vs. optional, and whether "unknown" differs from "not applicable"
  (`voidable` — common in exchange standards);
- code lists: closed (enum) or open/extensible, who maintains them;
- units of measure, time zones, coordinate reference systems for geometries;
- derived attributes (computed, not stored);
- cross-attribute and cross-object rules (put them in `constraints`).

Go class by class or in small batches; don't drop a wall of 80 questions on the user.

### Phase 4 — Versioning and historisation of *data*

This is about the instances, not the schema. Ask per object type (propose defaults):

- Do changes need to be kept? none / audit trail only / full version history.
- Which time dimensions: *valid time* (when it is true in reality), *transaction time*
  (when the system knew it), or both (bitemporal)?
- Lifecycle states (draft, active, retired…), and whether deletions are physical or logical.
- Retention periods and legal requirements.

Record per class in `history:`. `references/versioning-and-compatibility.md` describes the
patterns and how they map to each target.

### Phase 5 — Non-functional requirements

Ask per object type and record in `nfr:`: expected volume now and growth rate, read/write
ratio and typical access paths (what is queried by what), latency or throughput targets,
payload size limits for exchange, data classification (personal data / confidential) and
retention. Use them for physical decisions: indexes, partitioning, whether to denormalise,
whether to split large compositions out of exchange documents. Say explicitly when a
requirement has no influence on the neutral model but will matter for a specific export.

### Phase 6 — Review, export and release

1. Run `validate`; fix errors, discuss warnings.
2. Walk the user through the open questions and assumptions that remain.
3. Read `references/exports.md` for how neutral concepts map to each target. Confirm the
   mapping decisions (inheritance strategy, composition nesting, enum representation, ID
   strategy, XML attributes vs. elements) with the user and log them. Preview the
   generated output with `dmtool.py export … --format all -o <tmp dir>`.
4. On the user's go-ahead, run `dmtool.py release datamodel --dry-run`, show the plan, then
   run it without `--dry-run`. The first release is normally `1.0.0`; pass
   `--version 0.1.0` or similar while the model is still unstable. Complete the generated
   CHANGELOG entry with sources, decisions and migration notes.

## Amending an existing model

Triggered by new documents, change requests, or direct instructions ("add X", "we also
need Y").

1. **Load context**: read `model.yaml`, `decisions.md`, `open-questions.md`, the latest
   CHANGELOG entry and `sources.md`. Note the last released version.
2. **Ingest the new input** as in Phase 0 and register it as a new source.
3. **Impact analysis**: map each new requirement to existing elements — already covered,
   needs extension, contradicts an existing element or decision, or is new. Contradictions
   with earlier decisions are discussed, not overwritten.
4. **Propose a change set** as a short list, each item tagged with its compatibility
   impact. Prefer the non-breaking way of achieving the same thing; see the
   "Avoiding breaking changes" table in `references/versioning-and-compatibility.md`
   (add optional instead of required, deprecate instead of remove, add a new attribute
   instead of retyping, widen instead of narrow, …).
5. **Apply** the accepted changes to `model.yaml`, with `since:` on new elements and
   `deprecated:` on retired ones, and new source/decision references. Set `status: draft`
   while working; `release` sets the version. Rules that only apply to data created from
   now on get `scope: new`; rules that are only checked as warnings get
   `enforcement: warning`. Neither breaks existing data.
6. **Verify** with `dmtool.py diff releases/<last>/model.yaml model.yaml`. The tool
   classifies each change and recommends a version bump. It reports two kinds of break:
   - `BREAKING`: existing data or every consumer is affected.
   - `CONSUMERS`: only consumers that validate strictly against the released schema are
     affected. In strict mode even an optional field or a new value in a closed list
     counts.

   For either kind, tell the user what breaks for whom and the options: a non-breaking
   alternative, a projection that leaves out the new elements for old consumers, or a
   major version. Get an explicit decision and log it in `decisions.md` with migration
   guidance (SQL migration, transformation notes for exchange partners).
7. Release when the user says so (`dmtool.py release`, see Phase 6). Complete the
   generated CHANGELOG entry.

Never edit files under `releases/` — they are the record of what was promised.

## Interaction style

- Lead with a proposal, then ask. "I'd model *Permit* and *PermitApplication* as separate
  classes because the application has its own lifecycle (S2, §3) — OK?" is easier to
  answer than "How should permits be modelled?".
- Batch questions (roughly 3–7 per round), number them, give a recommended default for
  each, and mark which ones block progress.
- Keep a visible list of assumptions you made to keep moving, and log them in
  `open-questions.md` so they get confirmed later rather than forgotten.
- Use the user's domain vocabulary, and record synonyms in `glossary.md`. Talk to the user
  in their language. When the model has several documentation languages, write every
  definition and label in all of them: `validate` lists missing translations, and
  `release` refuses to run while any are missing.
- Show diagrams and compact tables instead of long YAML when discussing the model; the
  user should not need to read YAML to review it.
- If the user wants speed ("just draft something"), make reasonable assumptions, mark
  them, and produce a complete draft — then go through the assumptions afterwards.

## Reference files

- `references/model-format.md` — canonical YAML format, neutral types, multiplicities. Read before writing or editing `model.yaml`.
- `references/source-ingestion.md` — how to extract model candidates from each input type.
- `references/versioning-and-compatibility.md` — data historisation patterns, schema versioning, change classification, non-breaking alternatives, deprecation.
- `references/exports.md` — mapping rules and decisions for XSD, JSON Schema, PostgreSQL, and guidance for OWL/SHACL, OpenAPI, Avro/Protobuf, GraphQL.
- `assets/model-template.yaml` — worked example of a complete model (bilingual en/de).
