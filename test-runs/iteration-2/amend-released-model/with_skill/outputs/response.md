I've worked all six CR-7 items into the model without breaking anything for existing data or for partners who stay on 1.0.0. Three new optional fields remain, and your partners' strict validators would reject them, so how they reach the partners is your decision. Because of that I left the model as an **unreleased draft** and did not create a new version.

## What I decided, per CR-7 item

| # | CR-7 asks | What I did | Why |
|---|-----------|------------|-----|
| 1 | Rename `reference` → `fileNumber` | Kept the field name `reference` and gave it the label **"File number"**. It shows up as "File number" on the review page, in DB column comments and in the glossary. The real rename is on the list for the next major version. | A rename breaks all three partners and the database. The clerks see labels, not field names in the exchange data. |
| 2 | Applicant mandatory (name, optional organisation, address) | New type `Applicant` and `Permit.applicant`, **optional in the schema**. A new rule C-002 makes it **mandatory for every permit created from the new version on**. | A mandatory field would make ~2M existing permits invalid, and for many the applicant isn't known. |
| 3 | New status "expired" | **Not stored as a status.** It is calculated instead (rule C-005): status = granted and the validity end has passed. | Adding a value to the closed status list breaks strict partners. "Expired" also changes just because time passes, which would need a batch job and would create needless entries in the permit history. |
| 4 | `validUntil` with time of day | New field `validUntilDateTime` (date and time with time-zone offset). `validUntil` is kept but marked deprecated. For new permits both must be filled and agree (C-004), so old partners still see the right day. | Changing the field's type would break everyone. |
| 5 | Condition category | New code list `ConditionCategory` (environmental, safety, other) and `PermitCondition.category`, optional. I made the list **extensible**, so new categories later need no new model version and don't break partners. | I found no standard list to reuse. The INSPIRE registry and EU Vocabularies have none, and the closest Eionet list covers something else (the legal basis of conditions). |
| 6 | Drop `keywords` | **Marked deprecated, not removed.** Producers simply stop filling it; an empty list is still valid for old partners. Removal is planned for the next major version. | Removing it breaks old data and every partner. |

Each choice is logged with its reasons in `datamodel/decisions.md` (D-003 to D-009).

## Impact
- **Database:** additions only. The draft migration `datamodel/exports/unreleased/migrate-from-1.0.0.sql` adds one lookup table, seven nullable columns and one foreign key. It needs no backfill and does nothing to existing data. I have not run it.
- **Partners:** only three new optional fields: `applicant`, `validUntilDateTime` and `conditions[].category`. Because partners validate strictly against the closed 1.0.0 JSON Schema (D-002), they would reject documents that contain them. Partners still on 1.0.0 must receive documents without those three fields. Nothing else in the exchange format changes.
- **Producing application:** the rules for new permits (C-002 to C-004) are not checked by the generated database schema. Your application has to enforce them and calculate "expired".

## What you need to decide
1. **How the new fields reach the partners (this blocks the release, Q-001):**
   - **Recommended:** the exchange interface sends each partner documents in the version it implemented, leaving out the three new fields until that partner upgrades. That makes this a 1.1.0.
   - **Otherwise:** a 2.0.0 that also does the postponed breaking items: the real `fileNumber` rename, removing `keywords` and `validUntil`, and switching the exchange schema to open content so future additions stop breaking partners. That needs a migration period.
   - **Tool problem:** `dmtool` reads the "send each partner its version" setting from the 1.0.0 snapshot, which doesn't have it. So `release` refuses 1.1.0 and demands 2.0.0 even after you choose that option. Releasing as 1.1.0 needs the tool fixed or a logged override. The new elements are tagged `since: 1.1.0`; change that if you go to 2.0.0.
2. **Time zone** for `validUntilDateTime`, and which producing systems can supply a time at all (Q-002). I assumed the issuing authority's local time zone (A-001).
3. **Applicant data is personal data (Q-004).** I changed the permit's data classification from `internal` to `personal`. You need to settle the retention period and whether all three partners may receive it.
4. **Smaller points:** does the applicant need its own identity, e.g. to search "all permits of X" (Q-003)? Must new conditions have a category (Q-005)?

## Files
- Updated: `datamodel/model.yaml` (status `draft`), `sources.md` (S2 = CR-7), `decisions.md`, `open-questions.md`, `glossary.md`, and `CHANGELOG.md` (an "Unreleased" entry with notes for the partners).
- New: `datamodel/review.md` (the review page, no YAML needed) and preview exports in `datamodel/exports/unreleased/`: `schema.json`, `schema.xsd`, `schema.sql`, the migration script, the diagram and the compatibility report from `dmtool diff`.
- `releases/1.0.0/` and `exports/1.0.0/` are unchanged.
- The final exports appear in `exports/<version>/` when you run `python scripts/dmtool.py release datamodel`, once item 1 is decided.

Sources for the code-list check:
- [INSPIRE registry (EU Vocabularies)](https://op.europa.eu/en/web/eu-vocabularies/inspire-registry)
- [Eionet PermitConditionsBasisTypeCode](https://dd.eionet.europa.eu/vocabulary/IEDAnnexIIModule3/PermitConditionsBasisTypeCode/view)
