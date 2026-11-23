# Decisions

## D-001 Permit identifiers are UUIDs (2026-04-02)
Permits are exchanged with three municipal partner systems. Choice: UUID, stable across systems.

## D-002 Exchange format is JSON with closed content (2026-04-10)
Partners validate strictly against the JSON Schema of the release they implemented.

## D-003 CR-7 is implemented without breaking existing data or the 1.0.0 wire format (2026-11-23)
Context: CR-7 (S2) asks for six changes. The model is released as 1.0.0, and three partner systems validate strictly against the closed JSON Schema (D-002). Taken literally, items 1, 2, 4 and 6 are breaking (rename, new mandatory field, type change, removal), and item 3 adds a value to a closed enum.
Choice: implement every item in its non-breaking form (D-004 to D-008). The only remaining impact is three new *optional* properties, which strict consumers reject unless they get a projection (D-009).
Rationale: the model owner explicitly wants to avoid breaking partners "unless there's no other way", and there is another way for every item.
Status: decided by the modeller while the owner was unavailable. To be confirmed by the owner.

## D-004 `Permit.keywords` is deprecated, not removed (CR-7 item 6) (2026-11-23)
Removing it breaks old data and every consumer. It is marked deprecated in the next release: producers stop filling it (it is 0..*, so an empty list stays valid for old consumers). Removal is planned for the next major version.

## D-005 "File number" becomes the label of `reference`, not a rename (CR-7 item 1) (2026-11-23)
Options:
- (a) Rename `reference` to `fileNumber`. This breaks all three partners and the database.
- (b) Add `fileNumber` and deprecate `reference`. This duplicates a unique business key in every message and table during the transition.
- (c) Keep the identifier and label it "File number".

Choice: (c). Clerks see labels (forms, review page, column comments), not wire identifiers. Renaming the identifier from `reference` to `fileNumber` is on the backlog for the next major version (Q-006).

## D-006 Time-of-day validity via a new attribute; "expired" is derived, not stored (CR-7 items 3 and 4) (2026-11-23)
- Item 4: changing `validUntil` from date to dateTime is a type change, which breaks everyone. Instead, a new `validUntilDateTime` (dateTime with offset, 0..1, voidable) is added and `validUntil` is deprecated (replacedBy `validUntilDateTime`). During the transition, producers fill both. For data created from this release on, `validUntil` must be the local date of `validUntilDateTime` (C-004), so old consumers still see the right day. C-003 extends the decisionDate ordering rule to the new attribute.
- Item 3: adding `expired` to the closed `PermitStatus` enum breaks strict consumers. "Expired" also changes with the passing of time rather than with a business event. Storing it would need a batch job and would create spurious versions in the versioned permit history. Instead, "expired" is a documented derivation rule (C-005): status = granted and the validity end lies in the past. Applications and reports compute it, and PostgreSQL can expose it as a view.
- For old permits without a time, validity ends at the end of the `validUntil` day (assumption A-002).

## D-007 Applicant as a value type: optional in the schema, mandatory for new permits (CR-7 item 2) (2026-11-23)
A mandatory attribute would invalidate ~2 million existing permits, many with an unknown applicant.
Choice:
- New datatype `Applicant` (name, optional organisation, `Address`).
- Attribute `Permit.applicant` with multiplicity 0..1.
- Rule C-002 (enforced, `scope: new`): every permit created from this release on must have an applicant.

The applicant can become mandatory (`1`) in a later major version, but only if old permits are back-filled or retired.
It is a value type, not a class, because CR-7 describes it as data recorded on the permit. CR-7 asks for no identity, deduplication or queries across permits (Q-003). The permit's data classification goes from `internal` to `personal` (Q-004).

## D-008 Condition category as an extensible local code list (CR-7 item 5) (2026-11-23)
New enumeration `ConditionCategory` (environmental, safety, other), and attribute `PermitCondition.category` 0..1, because existing conditions are uncategorised.
- Vocabulary check: no standard list fits. The INSPIRE registry and EU Vocabularies have no permit-condition category list. The Eionet IED vocabulary "PermitConditionsBasisTypeCode" (https://dd.eionet.europa.eu/vocabulary/IEDAnnexIIModule3/PermitConditionsBasisTypeCode/view) covers the legal basis of BAT conditions (values A and B), which is a different concept.
- `extensible: true`, so a later category (e.g. noise, water) needs no model release and does not break strict partners' enum validation. The permits team maintains the list.

## D-009 Compatibility strategy for the three new optional properties (2026-11-23): PENDING owner decision
In strict-consumer mode, `dmtool diff` reports three optional additions as consumer-breaking: `Permit.applicant`, `Permit.validUntilDateTime` and `PermitCondition.category`. Strict JSON Schema validators with closed content (D-002) reject them. Options:
1. **Projection (recommended).** The exchange interface keeps sending 1.0.0-shaped documents to partners still on 1.0.0, without the three new properties and with `validUntil` still filled. Each partner upgrades when ready. Then set `compatibility.projection: true` and release as **1.1.0**.
2. **Major version 2.0.0.** Bundle the deferred breaking items: rename to `fileNumber`, remove `keywords` and `validUntil`, and make the applicant mandatory if old permits are back-filled. Switch to open content at the same time (`exportOptions.jsonschema.closed: false` plus a must-ignore rule), so future optional additions stop breaking partners. Needs a migration period for the partners.
3. **Keep CR-7 internal.** Leave the CR-7 fields out of the exchange interface until the partners agree.

Not decided, because the version number depends on this choice. The model is left as an unreleased draft (`status: draft`, version still 1.0.0).
Tool note: `dmtool diff` and `release` read `compatibility.projection` from the previous release, and 1.0.0 doesn't have the flag. So the tool still demands 2.0.0 after option 1 is chosen (tested on a scratch copy: `release --version 1.1.0` is refused). A 1.1.0 release needs either a tool fix or an explicit, logged override.
