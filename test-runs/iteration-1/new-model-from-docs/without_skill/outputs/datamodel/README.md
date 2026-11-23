# Urban Tree Cadastre: data model (draft v0.1)

This is a first draft, built from requirements v0.3 and the legacy schema dump of 2026-09-30.
The assumptions behind it still need review; they are listed in `ASSUMPTIONS.md`, most important first.

## Contents

| File | What it is |
|---|---|
| `ASSUMPTIONS.md` | All assumptions (A-01 … A-33) and the 7 questions to answer first. **Start here.** |
| `model.md` | Logical model: ER diagram (Mermaid), entity list, design decisions, requirement traceability |
| `legacy_mapping.md` | Column-by-column mapping from `baum` / `kontrolle` / `massnahme` |
| `sql/01_schema.sql` | PostgreSQL/PostGIS DDL: types, tables, constraints, indexes, comments |
| `sql/02_rules_and_audit.sql` | Triggers (audit log, deletion ban, location history, business rules) and roles/grants |
| `sql/03_views.sql` | App views (map, latest vitality, open measures, compensation), `opendata.tree`, and `exchange.build_exchange_file()` |
| `sql/04_codelists_seed.sql` | Starting code lists (vitality, priority, defects, measure types, felling reasons). **Placeholders.** |
| `sql/05_migrate_legacy.sql` | One-off legacy migration with mapping tables, guards and a reject log |
| `json/tree-exchange.schema.json` | JSON Schema (draft 2020-12) for the monthly exchange file to the regional agency |
| `json/tree-exchange.example.json` | Example exchange file that validates against the schema |

## How to install

```bash
psql -d trees -v ON_ERROR_STOP=1 -f sql/01_schema.sql
psql -d trees -v ON_ERROR_STOP=1 -f sql/02_rules_and_audit.sql
psql -d trees -v ON_ERROR_STOP=1 -f sql/03_views.sql
psql -d trees -v ON_ERROR_STOP=1 -f sql/04_codelists_seed.sql
# load species list, parks, street segments; restore legacy dump into schema "legacy"; then:
psql -d trees -v ON_ERROR_STOP=1 -f sql/05_migrate_legacy.sql
```

The app must set the acting user in every transaction:
`SET LOCAL app.actor = '<login>'`. It can also set `SET LOCAL app.change_reason = '...'` when correcting a location.

## Verification status

- **JSON Schema:** checked with `jsonschema` 4.26 (Draft 2020-12, format checking on). The example file validates. 13 deliberately broken variants are rejected, for example:
  - a living tree with felling data
  - an inspector name instead of a pseudonym
  - a missing defect severity
  - a done measure without a completion date or contractor
  - an easting that still has the zone prefix

  Legacy records with the relaxed fields set to NULL are accepted.
- **SQL:** **not executed.** There was no PostgreSQL/PostGIS instance available. The scripts were reviewed by hand, including a check that brackets and blocks are balanced. Before relying on them, run all files against a PostgreSQL 15+/PostGIS 3.3+ test database, then:
  - validate the output of `exchange.build_exchange_file()` against the schema
  - benchmark the map query with about 180k trees and about 6 M inspections
