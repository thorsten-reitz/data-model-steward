# data-model-steward
A Skill for LLMs to write and maintain specifications for domain data models, with various export paths.

## Contents

- [`data-model-steward/`](data-model-steward/): the skill
  - [`SKILL.md`](data-model-steward/SKILL.md): workflow for creating a model (sources → goals/usage → object types → attributes → data history → non-functional requirements → release) and for amending it later
  - [`references/`](data-model-steward/references/): canonical model format, source ingestion, versioning & compatibility rules, export mappings
  - [`scripts/dmtool.py`](data-model-steward/scripts/dmtool.py) (needs Python 3 and PyYAML):
    - `init`: creates a model workspace.
    - `validate`: checks the model, including missing translations.
    - `diagram`: draws a Mermaid class diagram.
    - `export`: generates JSON Schema, XSD and PostgreSQL DDL, in any of the model's documentation languages.
    - `diff`: classifies changes as breaking, breaking for strict consumers, or compatible, and recommends a version bump.
    - `release`: validates, snapshots, regenerates the exports and drafts the CHANGELOG entry.
  - [`assets/model-template.yaml`](data-model-steward/assets/model-template.yaml): worked example (bilingual en/de)
  - [`evals/`](data-model-steward/evals/): test cases in the `claude plugin eval` layout
- [`test-runs/`](test-runs/): outputs and grading of the test cases, with and without the skill

## Using the skill

Copy or symlink `data-model-steward/` into your skills directory (e.g. `~/.claude/skills/`), or
package it as a `.skill` file. The skill keeps each model in a `datamodel/` folder in your project:
`model.yaml` is the source of truth, and every schema is generated from it.

Identifiers can be in any language; exporters transliterate them to ASCII. Definitions and
labels can be written in several languages (`model.languages.documentation`).

```
python data-model-steward/scripts/dmtool.py init datamodel --name PermitRegistry --languages en,de
python data-model-steward/scripts/dmtool.py validate datamodel/model.yaml
python data-model-steward/scripts/dmtool.py release datamodel --dry-run
```
