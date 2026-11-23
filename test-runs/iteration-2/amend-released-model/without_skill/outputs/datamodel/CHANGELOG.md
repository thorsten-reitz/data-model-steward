# Changelog

## 1.1.0 - draft (not yet released) - CR-7
Minor, backward-compatible release. Sources: S1, S2 (CR-7).

Compatibility: every document valid against the 1.0.0 JSON schema is valid against 1.1.0, and the
database migration is additive and keeps all data. Because the exchange schema is closed (D-002),
documents that *use* the new properties are rejected by partners still validating against 1.0.0,
so the new properties must only be sent to partners that have adopted 1.1.0 (D-008).

Added
- `Permit.applicant` (datatype `Applicant`: name, organisation 0..1, address) - CR-7 item 2. Optional in the schema; mandatory for permits created from go-live (C-002, enforced on insert).
- `Permit.validUntilTime` (time of day, authority-local; absent = end of day) - CR-7 item 4. C-003: only together with validUntil.
- `PermitCondition.category` with enumeration `ConditionCategory` (environmental, safety, other) - CR-7 item 5. Mandatory for new conditions (C-004, enforced on insert).
- Derived status "expired": enumeration `DerivedPermitStatus` and database view `permit_effective_status` - CR-7 item 3. Not transmitted in the exchange format (D-005).
- Persistence only: `created_at` on permit and permit_condition (basis for C-002/C-004); partial index on valid_until.

Changed
- `Permit.reference` is labelled "File number" (business term fileNumber) in model, schema and DB comments - CR-7 item 1. Technical name unchanged (D-003).

Deprecated
- `Permit.keywords` - CR-7 item 6. Still accepted, should no longer be sent or populated; removal planned for 2.0.0 (D-007).

Exports: exports/1.1.0/schema.json, exports/1.1.0/schema.sql, exports/1.1.0/migrate-1.0.0-to-1.1.0.sql.

Candidates for a future 2.0.0 (breaking, not scheduled): rename reference -> fileNumber; remove
keywords; possibly merge validUntil/validUntilTime into one date-time; possibly transmit "expired";
possibly make applicant/category required once legacy data is cleaned up.

## 1.0.0 - 2026-05-01
First release. Sources: S1.
