# Test runs

Outputs of the skill's test cases (`data-model-steward/evals/`), kept as worked examples and as
a baseline for later iterations. These files are model-generated and unreviewed. Read them as
examples of what the skill produces, not as reference models.

## Layout

```
iteration-N/
├── benchmark.md / benchmark.json     # pass rates, time and tokens, with analyst notes
└── <case>/
    ├── eval_metadata.json            # prompt and assertions
    ├── with_skill/                   # run that used the skill
    │   ├── outputs/                  # the run's working directory (inputs + everything it wrote, incl. response.md)
    │   ├── grading.json              # per-assertion verdicts with evidence
    │   └── timing.json
    └── without_skill/                # baseline: same prompt, no skill
```

## Iteration 1 (2026-11-23): summary

| Case | With skill | Without skill |
|---|---|---|
| new-model-from-docs (tree cadastre from requirements + legacy DDL) | 11/11 | 10/11 |
| amend-released-model (change request CR-7 against released 1.0.0) | 10/12 | 10/12 |
| reverse-engineer-xsd (air quality XSD to canonical model + JSON Schema) | 10/10 | 8/10 |

Known issues found in this iteration (to address in iteration 2):

- Two assertions in `amend-released-model` (the `expired` status value, and adding `fileNumber`)
  were too strict. Both runs correctly avoided them because partners validate with closed content.
- Most assertions don't tell the two runs apart; the baseline is already competent at core modelling.
- Tool gaps: `dmtool` can't produce XML attributes or integer code lists, `diff` treats every new
  constraint as breaking, and the PostgreSQL export doesn't add GiST indexes for spatial access paths.
- None of the generated SQL was run against a real PostgreSQL database.

Since iteration 1, the assertions have been reworded and extended (`data-model-steward/evals/*/graders`).
`dmtool` now supports XML attributes, integer code lists, consumer-aware `diff`
(strict/tolerant, projection), constraint `scope`/`enforcement`, `init` and `release`, and
multilingual documentation. The GiST index gap and the SQL test are still open.

## Iteration 2 (2026-11-23): summary

The skill now includes `migrate`, `docs` and vocabulary reuse. The assertions are those of
iteration 2 (14/14/13), and both configurations were re-run.

| Case | With skill | Without skill |
|---|---|---|
| new-model-from-docs | 14/14 | 11/14 |
| amend-released-model | 14/14 | 12/14 |
| reverse-engineer-xsd | 13/13 | 9/13 |
| mean time / tokens | 350 s / 130k | 354 s / 103k |

The analyst notes are in `iteration-2/benchmark.md`. In short:
- **Discrimination:** the assertions now separate the runs. Part of the gap still comes
  from checks that reward the skill's method (single canonical model, volumes in the
  model, vocabulary check).
- **Where the baseline was stronger:**
  - tree cadastre: trigger-filled location history, business rules in the exchange
    schema, and a full legacy migration script;
  - XSD: a clearer note on the API read model.
- **Issues found:**
  - `projection` was read only from the old release;
  - rules on brand-new attributes were reported as breaking;
  - the draft version stayed at 1.0.0, so previews carried the old `$id`;
  - the XSD compatibility check used only one sample;
  - the location-history check accepted a table without capture.

Fixed since iteration 2, but not yet re-run:
- `dmtool` reads `projection` from either version, and rules that only touch new
  attributes count as minor.
- The skill now asks for the draft version, hand-written triggers and `if`/`then` rules,
  and edge-case XSD tests.
- The assertions were sharpened, and new ones check exchange-schema business rules,
  additive-only migrations, and code lists that are only assumed. There are now 15, 15
  and 13 assertions.
