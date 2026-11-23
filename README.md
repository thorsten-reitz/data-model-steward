# data-model-steward
A Skill for LLMs to write and maintain specifications for domain data models, with various export paths.

## Contents

- [`data-model-steward/`](data-model-steward/): the skill
  - [`SKILL.md`](data-model-steward/SKILL.md): workflow for creating a model (sources → goals/usage → object types → attributes → data history → non-functional requirements → release) and for amending it later
  - [`references/`](data-model-steward/references/): canonical model format, source ingestion, versioning & compatibility rules, export mappings
  - [`scripts/dmtool.py`](data-model-steward/scripts/dmtool.py): `validate`, `diagram` (Mermaid), `export` (JSON Schema, XSD, PostgreSQL DDL), `diff` (classifies changes as breaking/compatible, recommends a version bump). Needs Python 3 and PyYAML.
  - [`assets/model-template.yaml`](data-model-steward/assets/model-template.yaml): starting point and worked example
  - [`evals/`](data-model-steward/evals/): test cases in the `claude plugin eval` layout
- [`test-runs/`](test-runs/): outputs and grading of the test cases, with and without the skill

## Using the skill

Copy or symlink `data-model-steward/` into your skills directory (e.g. `~/.claude/skills/`), or
package it as a `.skill` file. The skill keeps each model in a `datamodel/` folder in your project:
`model.yaml` is the source of truth, and every schema is generated from it.
