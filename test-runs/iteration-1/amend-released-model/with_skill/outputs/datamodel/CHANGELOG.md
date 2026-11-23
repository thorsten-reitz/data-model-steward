# Changelog

## 1.1.0 - unreleased (draft, prepared 2026-11-23)
Sources: S2 (change request CR-7, permits team, 2026-11-15). Decisions D-003 to D-011.

### Added
- Datatype `Applicant` (name, organisation 0..1, address) and `Permit.applicant` (0..1, voidable) - CR-7 item 2, D-005.
  Rule C-002 (warning level, not schema-enforced): required for every permit recorded from 1.1.0 on.
- `Permit.validUntilDateTime` (dateTime with UTC offset, 0..1, voidable) - CR-7 item 4, D-007.
  Rule C-003 keeps it consistent with `validUntil` and `decisionDate`.
- Enumeration `ConditionCategory` (environmental, safety, other; extensible, maintained by the permits team)
  and `PermitCondition.category` (0..1) - CR-7 item 5, D-008.
- Derived state "expired" (granted and validity end passed), documented on `Permit`; PostgreSQL view
  `permit_registry.permit_with_expiry` in exports/1.1.0/views.sql - CR-7 item 3, D-006. No new `PermitStatus` value.
- First XSD export (exports/1.1.0/schema.xsd) - D-011.

### Changed
- `Permit.reference` is now documented as the "file number" (business term from CR-7 item 1); name unchanged - D-004.
- `Permit` data classification: internal -> personal (applicant data).

### Deprecated
- `Permit.validUntil` - replaced by `Permit.validUntilDateTime`; keep populating it; removal planned for the next major.
- `Permit.keywords` - no longer used (CR-7 item 6); stop populating it; removal planned for the next major.

### Compatibility
- No breaking change for existing data: everything added is optional; nothing renamed, retyped or removed.
- Exchange partners on 1.0.0 (closed JSON content, D-002): a 1.1.0 document is a valid 1.0.0 document **only if**
  it omits `applicant`, `validUntilDateTime` and `conditions[].category`. Until a partner upgrades, send it
  documents without them (D-010). Examples: exports/1.1.0/examples/.
- Partners upgrading to 1.1.0 should accept the three new properties, read `validUntilDateTime` in preference
  to `validUntil`, stop relying on `keywords`, and treat `category` as an open code list (unknown values allowed).
- `dmtool diff` lists C-002 and C-003 as breaking; they cannot invalidate existing data (see D-003).

### Migration (PostgreSQL)
- exports/1.1.0/migrate_1.0.0_to_1.1.0.sql: additive only (lookup table, nullable columns, a CHECK that keeps the
  applicant complete, comments). No backfill. Not yet run against a database.
- exports/1.1.0/views.sql: expiry view; set `permit_registry.local_time_zone` (Q-006).

### Not done from CR-7 (deferred to a possible 2.0.0, see Q-001)
- Physical rename `reference` -> `fileNumber`; schema-enforced mandatory applicant; removal of `keywords`
  and `validUntil`; `expired` as a stored status.

## 1.0.0 - 2026-05-01
First release. Sources: S1.
