# Changelog

## 1.1.0 - unreleased (draft, 2026-11-23)
Implements change request CR-7 (S2). Minor version: backward compatible with 1.0.0. Every valid 1.0.0
document and database stays valid. See exports/1.1.0/compatibility.md.

- Added: `Applicant` datatype (name, optional organisation, address) and optional `Permit.applicant`.
  Required for permits registered from the cut-over on (constraint C-002). CR-7 item 2.
- Added: `Permit.validUntilTime` (local time of day of expiry; absent = end of day) and constraint C-003. CR-7 item 4.
- Added: enumeration `ConditionCategory` (environmental, safety, other) and optional `PermitCondition.category`. CR-7 item 5.
- Added: derived `Permit.expired` and the database view `permit_effective_status` (effective status "expired").
  `PermitStatus` is unchanged. CR-7 item 3, D-005.
- Changed (documentation only): `Permit.reference` is labelled "File number" with the alias `fileNumber`.
  The technical name is unchanged until 2.0.0. CR-7 item 1, D-003.
- Deprecated: `Permit.keywords`, to be removed in 2.0.0. CR-7 item 6, D-006.
- Exports: exports/1.1.0/schema.json, schema.sql, migration-from-1.0.0.sql, compatibility.md.

## 1.0.0 - 2026-05-01
First release. Sources: S1.
