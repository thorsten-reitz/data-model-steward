# Reusing standard code lists and vocabularies

A code list someone else maintains is usually better than one you invent. It has agreed
definitions, stable URIs, translations and a maintenance process. Partners and
regulations often require one anyway. For every enumeration in the model, check first
whether a suitable standard exists. Recommend reuse when it fits; the user decides.

## Contents
1. Where candidates come from
2. Assessing fit
3. Searching online
4. Proposing candidates to the user
5. Adopting a vocabulary in the model
6. Gaps, extensions and subsets
7. Maintenance

## 1. Where candidates come from

Check in this order:

1. **The input materials.** Look for:
   - code lists or vocabularies described or referenced in specs, regulations and data
     dictionaries;
   - registers such as the INSPIRE registry, EU Vocabularies or national registers;
   - `codeSpace` and `xlink:href` code-list references in XSDs, and annotations like
     "code from the … vocabulary";
   - SKOS/RDF files, CSV code tables, and lookup tables in legacy databases that copy a
     standard list.

   Register each one in `sources.md` and note which enumeration it could serve.
2. **Standards the model already aligns with** (`model.standards`): their code lists come
   with them.
3. **Online search** (section 3), only when 1 and 2 give nothing suitable.

## 2. Assessing fit

Check each candidate against these criteria and write down the result. A candidate
doesn't need to pass all of them, but the user must see where it falls short.

| criterion | question |
|-----------|----------|
| coverage | Does it contain the values the use cases need? Which are missing, and which are superfluous? |
| meaning | Do its definitions match the model's definition of the concept, not just the labels? |
| granularity | Is it too coarse or too fine (e.g. 900 species vs. 12 genus groups)? Does a hierarchy allow choosing a level? |
| authority | Who maintains it? Is it normative for this domain or jurisdiction, or required by partners or regulation? |
| stability | Are there stable, dereferenceable URIs per value? Versioning? Deprecation instead of deletion? |
| languages | Are labels available in the model's documentation languages? |
| licence | May it be copied and redistributed (snapshot in exports)? Is attribution required? |
| maintenance fit | Does its update cycle match the model's? Can the user propose additions? |

Verdicts: **reuse as is** · **reuse a subset** · **reuse plus local extension**
(section 6) · **don't reuse** (give the reason).

## 3. Searching online

If no suitable vocabulary is in the input materials and a web search or fetch tool is
available, search for one yourself. You don't need to ask first, but adopt nothing without
the user's OK. Start with authoritative registries. The list below gives starting points,
not an exhaustive or binding list.

- **Cross-domain and EU:**
  - EU Vocabularies / Publications Office authority tables (countries, languages, currencies, file types, corporate bodies), EuroVoc — https://op.europa.eu/en/web/eu-vocabularies
  - INSPIRE registry and code lists (spatial and environmental themes) — https://inspire.ec.europa.eu/registry
- **Environment:**
  - EEA/Eionet Data Dictionary vocabularies (e.g. air quality) — https://dd.eionet.europa.eu/vocabularies
  - GEMET thesaurus
- **International standards:**
  - ISO 3166 (countries), ISO 4217 (currencies), ISO 639 (languages)
  - IANA registries (media types, character sets)
- **Units of measure:** UCUM, QUDT.
- **Web and metadata:** schema.org enumerations; W3C vocabularies (DCAT, SKOS, ADMS).
- **Biology:** GBIF Backbone Taxonomy, World Flora Online (e.g. botanical species names).
- **National registers** for public administration, e.g. XRepository for German XÖV code lists.
- **Wikidata** only as a last resort, and never as the sole authority.

How to search:
- Search for the concept, not only the label, and in the domain's languages.
- Fetch the actual register page and check it. Don't propose a vocabulary you haven't
  seen, and never invent or guess URIs. If you can't verify a candidate, say so.
- Note the version or retrieval date and the licence as you find them.
- Without web access, name candidates from your own knowledge, clearly marked as
  unverified, and ask the user to confirm them.

## 4. Proposing candidates to the user

For each enumeration with candidates, show a compact table and a recommendation:

```
PollutantCode — candidates
| candidate | publisher | fit | gaps | licence | URIs |
| EEA AQ pollutant vocabulary (dd.eionet.europa.eu/vocabulary/aq/pollutant) | EEA | reuse subset: 6 of 6 needed pollutants present, normative for EU AQ reporting | none | CC BY 4.0 | yes, per value |
| own list (status quo) | — | full control | no shared semantics, partners map by hand | — | no |
Recommendation: reuse the EEA vocabulary as an extensible subset; keep the numeric EEA codes, exchange codes (not URIs) for compatibility with XSD 2.1.
```

Batch these questions with the Phase 3 questions. Record the decision, including
rejections and their reasons, in `decisions.md`.

## 5. Adopting a vocabulary in the model

Keep a reference to the source and a local snapshot of the values the model uses, with
their URIs. Exports and docs then work offline and stay reproducible, and the link to
the authority is kept.

```yaml
enumerations:
  Pollutant:
    description: {en: Air pollutant., de: Luftschadstoff.}
    extensible: true                 # usually true: the publisher may add values between model releases
    vocabulary:
      uri: http://dd.eionet.europa.eu/vocabulary/aq/pollutant    # register / code list URI (required)
      name: EEA air quality pollutant vocabulary
      publisher: European Environment Agency
      version: null                  # publisher's version, if any
      retrieved: 2026-11-23          # date of the snapshot (version or retrieved is required)
      licence: CC BY 4.0
      subset: true                   # the model uses only part of the vocabulary
      valueUriTemplate: "http://dd.eionet.europa.eu/vocabulary/aq/pollutant/{code}"   # or uri on each value
      represent: code                # code (default): data carries codes · uri: data carries value URIs
    values:
      - {code: "8", label: {en: Nitrogen dioxide (NO2), de: Stickstoffdioxid (NO2)}}
      - {code: "5", label: {en: Particulate matter (PM10), de: Feinstaub (PM10)}}
```

- Use the publisher's codes and labels; don't rename them. Add translations only where
  the publisher has none, and mark them in `notes`.
- `represent: uri` suits linked-data or INSPIRE-style exchange, where values are
  referenced by URI (`xlink:href`). `code` suits most databases and JSON APIs.
  Changing it later is a breaking change.
- Exports carry the provenance:
  - JSON Schema: `x-vocabulary` and `x-enumUris`.
  - XSD: a documentation note.
  - PostgreSQL: a lookup table with a `uri` column.
  - `docs`: the source and the value URIs.
- `validate` checks that the URI, a version or retrieval date, and value URIs are
  present. It flags snapshots older than a year.

## 6. Gaps, extensions and subsets

- **Subset:** take only the values the use cases need (`subset: true`). Say which ones
  were left out and why.
- **Missing values:** don't slip own values into the publisher's list. Options:
  1. Propose the addition to the publisher (best long-term).
  2. Create a separate local extension enumeration in the model's own namespace, and
     document how the two combine (e.g. an attribute that accepts either).
  3. Use local values with their own URIs under `model.namespace`, marked
     `notes: local extension`.

  Record the choice as a decision.
- **Different meaning:** if a candidate's definitions differ in substance, don't reuse
  it under the same name. Model your own list and add a mapping in `notes` or the glossary.

## 7. Maintenance

- During amendments, check reused vocabularies for new versions: look at `validate`'s
  snapshot-age notes and fetch the register. Update `retrieved`/`version` and the values,
  then run `diff`:
  - a snapshot update is a patch;
  - new values are minor;
  - removed or changed values, and a changed vocabulary URI or `represent`, are breaking.
- Publishers deprecate rather than delete. Mirror that with `deprecated:` on the value.
