# Test runs

Outputs of the skill's test cases (`data-model-steward/evals/`), kept as worked examples and as
a baseline for later iterations. These files are model-generated and unreviewed. Read them as
examples of what the skill produces, not as reference models.

## Layout

```
iteration-1/
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
