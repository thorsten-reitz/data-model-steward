# Changelog

## Unreleased (planned 1.1.0; 2.0.0 if the projection is not possible, see D-009 / Q-001), 2026-11-23
Sources: S2 (change request CR-7, permits team, 2026-11-15). Decisions: D-003 to D-009.
Preview exports: `exports/unreleased/` (regenerated, not a release; `dmtool release` writes the real ones into `exports/<version>/`).

### Added
- Datatype `Applicant` (name, organisation 0..1, address) and `Permit.applicant` (0..1): CR-7 item 2, D-007.
- `Permit.validUntilDateTime` (dateTime with offset, 0..1, voidable): CR-7 item 4, D-006.
- Enumeration `ConditionCategory` (extensible: environmental, safety, other) and `PermitCondition.category` (0..1): CR-7 item 5, D-008.
- Rule C-002: applicant is mandatory for permits created from this release on (`scope: new`).
- Rule C-003: `validUntilDateTime` must not be before `decisionDate` (`scope: new`).
- Rule C-004: for new data, `validUntil` must equal the local date of `validUntilDateTime` (`scope: new`).
- Rule C-005 (documented derivation): a permit is *expired* when status = granted and its validity end has passed. CR-7 item 3, D-006.

### Changed
- `Permit.reference` gets the label "File number" (the clerks' term). Identifier unchanged. CR-7 item 1, D-005.
- `Permit` data classification `internal` → `personal` (applicant data).

### Deprecated
- `Permit.keywords`: no longer used (CR-7 item 6, D-004). Producers stop filling it. Removal planned for the next major version.
- `Permit.validUntil`: replaced by `validUntilDateTime` (D-006). Producers keep filling it during the transition (C-004). Removal planned for the next major version.

### Not done as requested (deliberately)
- No rename `reference` → `fileNumber` (breaking). Done as a label instead and kept on the backlog for the next major version (Q-006).
- No stored status value `expired` (adding a value to a closed enum breaks strict consumers, and the value would change with time alone). It is derived instead (C-005).
- No type change of `validUntil` and no removal of `keywords` (both breaking). Handled as new attribute plus deprecation instead.

### Compatibility
- Existing data: fully compatible. All new attributes are optional, and the new mandatory rules apply only to new data. PostgreSQL: additive migration (`exports/unreleased/migrate-from-1.0.0.sql`): one lookup table, seven nullable columns, one foreign key. No backfill needed.
- Strict exchange partners (closed JSON Schema, D-002): `applicant`, `validUntilDateTime` and `conditions[].category` are new optional properties that a 1.0.0 validator rejects. Partners still on 1.0.0 must get a projection that omits them; `keywords` may simply be sent empty, and `validUntil` stays filled. No other wire change. Decision pending (D-009).
- Application changes needed: enforce C-002/C-003/C-004 for new permits in the producing application (they are not checked by the generated DDL); compute "expired" (C-005).

## 1.0.0 - 2026-05-01
First release. Sources: S1.
