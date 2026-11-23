I've worked CR-7 into the model as a **draft 1.1.0**, and none of it breaks the three partners. Four of the six items couldn't be done literally without breaking them, so I've marked those for a later 2.0.0.

Every document that is valid under 1.0.0 is also valid under 1.1.0, and the database upgrade only adds things. I tested the JSON schemas with a validator. I didn't run the SQL, because there was no PostgreSQL and no dmtool available. The released 1.0.0 files (`releases/1.0.0/`, `exports/1.0.0/`) are unchanged.

## What I did with each CR-7 item

| # | Request | What I did | Why |
|---|---|---|---|
| 1 | Rename `reference` to `fileNumber` | Kept the technical name `reference`. Added the label "File number", the alias `fileNumber` and a glossary entry. The real rename is planned for 2.0.0. | Renaming a required field breaks every partner, and it would only be cosmetic. Screens and documents can use "file number" now. |
| 2 | Every permit must have an applicant | New `Applicant` structure (name, optional organisation, address). It is optional in the schema, and new rule C-002 makes it required for permits created after a cut-over date. In the database this is a trigger on new records only. | We can't make up applicants for the ~2M old permits. Checking only new records means old permits can still be revoked or corrected. |
| 3 | New status "expired" | Not added to the status list. "Expired" is calculated instead: a granted permit whose end of validity has passed. A new database view `permit_effective_status` shows it. | A stored status would need a scheduled job to keep it in line with the validity date. Adding it to the fixed status list would also break the partners. |
| 4 | `validUntil` with a time of day | Added an optional `validUntilTime` (local time). If it's empty, the permit is valid until the end of the `validUntil` day. | Changing the date to a date-time breaks the partners. Converting old dates would mean guessing a time and time zone. Existing data keeps its meaning. |
| 5 | Category for conditions | New list `ConditionCategory` (environmental / safety / other) and an optional `category` field on conditions. | Existing conditions have no category. |
| 6 | Remove `keywords` | Marked as deprecated: we stop filling it, but it is still accepted. It is removed in 2.0.0, and the existing data is kept. | Removing it now would make 1.0.0 documents that contain keywords invalid, and would delete data permanently. |

**Something you need to know about the exchange format.** The JSON exchange schema rejects any field it doesn't know. So a partner still on 1.0.0 will reject documents that contain the new fields, even though those fields are optional. Our exchange interface therefore has to send 1.0.0 partners a stripped-down version: no applicant, no `validUntilTime`, no condition `category`. That loses nothing they already get today. The rules are in `datamodel/exports/1.1.0/compatibility.md`, and I tested this with sample documents.

## What changed in `datamodel/`
- `model.yaml`: now version 1.1.0, status `draft`. It has the new elements, rules C-002 and C-003 (a time only together with a date), the deprecation of `keywords`, and the new source S2 (the CR-7 document).
- `exports/1.1.0/schema.json`: the new JSON schema.
- `exports/1.1.0/schema.sql`: the full database definition.
- `exports/1.1.0/migration-from-1.0.0.sql`: upgrades the existing database. It only adds columns, so the ~2M rows aren't rewritten. The C-002 trigger is commented out until a cut-over date is set.
- `exports/1.1.0/compatibility.md`: what is compatible, how to strip documents for 1.0.0 partners, and what waits for 2.0.0.
- `CHANGELOG.md`, `decisions.md` (D-003 to D-007), `glossary.md`, `open-questions.md` (Q-001 to Q-008), `sources.md`.

## What you still need to decide (details in `open-questions.md`)
1. **Privacy of applicant data (Q-002).** This is the most important one. Applicants can be private persons, so this needs a privacy (DPO) review, a retention period, and a decision on whether partners may receive applicant data at all. If they may not, take `applicant` out of the exchange before releasing.
2. **Cut-over date for "applicant required" (Q-001).** Also check that every system that registers permits can capture the applicant by then.
3. **How 1.0.0 partners are served (Q-007).** Either a separate endpoint per version, or version negotiation. This must be in place before anyone sends 1.1.0 documents.
4. **Time zone for `validUntilTime` (Q-003).** I assumed the authority's local time. Please also confirm that existing dates mean "valid through the end of that day".
5. **Is a calculated "expired" enough for the permits team (Q-005)?** If they need it stored, or sent to partners as a status, that has to wait for 2.0.0.
6. **Categories for existing conditions (Q-004).** Leave them empty (my choice), fill them with "other", or classify them by hand? And should the category be required for new conditions?
7. **When to do 2.0.0 with the partners (Q-006).** It would carry the `fileNumber` rename, the `keywords` removal, and possibly merging the date and time into one date-time.
8. **Release 1.1.0.** Regenerate the exports with dmtool and compare them with my hand-written files. Test the SQL against a copy of the database. Then set the status to released and save a snapshot to `releases/1.1.0/`.
9. **XSD (Q-008).** `xsd` is listed as an output format, but 1.0.0 never had an XSD file. Is it still needed?
