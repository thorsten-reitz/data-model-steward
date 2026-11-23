I've worked CR-7 into the model as **version 1.1.0, a backward-compatible minor release**. None of the six items needed a breaking change. Two items (the rename and the keywords removal) are only partly done for now: the breaking part is left for a possible 2.0.0. I left 1.1.0 as a **draft** because releasing it is your call. The 1.0.0 snapshot and exports are untouched.

## What I decided, item by item

| CR-7 item | What 1.1.0 does | Why not exactly as requested |
|---|---|---|
| 1. `reference` should be `fileNumber` | Labelled "File number" (business name `fileNumber`) in the model, schema, DB comments and glossary. The technical name stays `reference`. | A rename in the closed JSON schema would break all three partners. The real rename is proposed for 2.0.0 (D-003). |
| 2. Applicant mandatory | New `applicant` (name, optional organisation, Address). It's optional in the schema, but a rule (C-002) makes it mandatory for every permit created after go-live. A DB trigger enforces this on INSERT only. | We don't know the applicant for many of the ~2M older permits, so a hard NOT NULL or required field would mean making up data (D-004). |
| 3. Status "expired" | Worked out from the data, not stored: `granted` plus a validity end in the past gives "expired". This is in the new view `permit_effective_status`, and the exchange format is unchanged. | Adding a value to the closed, non-extensible status enum would break partners. A stored status would also need a nightly job to keep it right (D-005). |
| 4. Time of day for validUntil | New optional `validUntilTime` (local time, e.g. `12:00`). If it's missing, the permit is valid until the end of the day, which is what all existing data already means. | Changing `validUntil` from a date to a date-time would break every partner and all existing values (D-006). |
| 5. Condition category | New enum `ConditionCategory` (environmental / safety / other) and `PermitCondition.category`. It's optional in the schema and enforced for new conditions (C-004). | Existing conditions have no category, and filling them all with "other" would mislabel them. |
| 6. Drop keywords | Marked **deprecated**: senders should omit it, receivers still accept it, and the data is kept. Removal is planned for 2.0.0. | Removing it now would reject documents from any partner that still sends it. "Nobody uses it" hasn't been confirmed for the partners (D-007). |

## Effect on the partners
- I tested the 1.1.0 JSON schema with sample documents. Every valid 1.0.0 document is also valid under 1.1.0, and the new checks work (bad category value, `validUntilTime` without `validUntil`).
- **Catch:** the schema is closed, so a document that uses the new fields (`applicant`, `validUntilTime`, `category`) **fails at a partner that still validates against 1.0.0**. I confirmed this with a test. So until a partner has switched to 1.1.0, we must leave out those fields when sending to that partner. Without them, a 1.1.0 document is a valid 1.0.0 document (D-008). Nothing forces the partners to change.
- The DB migration only adds things: no renames, no drops, no data loss. Every new column is nullable or has a default.

## What changed in `datamodel/`
- `model.yaml`: version 1.1.0 (draft), new types and attributes, constraints C-002 to C-005. Every change is marked with `since` / `deprecated` and points to the CR-7 source.
- `exports/1.1.0/schema.json`: the new JSON exchange schema.
- `exports/1.1.0/schema.sql`: full Postgres DDL for new installations.
- `exports/1.1.0/migrate-1.0.0-to-1.1.0.sql`: upgrade script for the existing database, run as one transaction.
- `CHANGELOG.md`, `decisions.md` (D-003 to D-008), `glossary.md`, `open-questions.md` (OQ-1 to OQ-8), `sources.md` (CR-7 added as S2).
- I did not create `releases/1.1.0/`. That snapshot gets made when you release.

## What you still need to decide
1. **Whether to release 1.1.0 as drafted**, and who tells the three partners and agrees when each one switches to the 1.1.0 schema (OQ-1).
2. **Whether you want a 2.0.0 at all**, for the real `fileNumber` rename, removing keywords and possibly a single date-time for validity. The permits team should hear that in 1.x "fileNumber" is only a label (OQ-2).
3. **Time zone for `validUntilTime`** (OQ-3). The "expired" view uses `Europe/Berlin` as a **placeholder**, so check it before running the migration.
4. **Whether partners use `keywords`**: this has to be answered before it can be removed (OQ-4).
5. **When the "applicant/category required" rule starts** (OQ-5). Right now it starts when the migration runs: every existing row counts as old, and rows added later must have both. Also decide whether to back-fill applicants from the paper files and give old conditions a category.
6. Smaller points: whether "expired" should ever be sent to partners (OQ-6), whether an applicant can be just an organisation with no person's name (OQ-7), and whether you still want XSD. `targets` lists it, but no XSD export ever existed, not even for 1.0.0, so I didn't make one (OQ-8).

## Caveats
- The SQL was written by hand from the 1.0.0 dmtool output, because there's no dmtool here. I haven't run it against a real Postgres, so please test it on a copy first, and regenerate with dmtool if you rely on it.
- The migration gives every existing row `created_at` = the time the migration runs. If the real creation dates matter (they're probably in `permit_history`), back-fill them afterwards.
