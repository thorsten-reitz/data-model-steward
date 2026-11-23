# Decisions

## D-001 Permit identifiers are UUIDs (2026-04-02)
Permits are exchanged with three municipal partner systems. Choice: UUID, stable across systems.

## D-002 Exchange format is JSON with closed content (2026-04-10)
Partners validate strictly against the JSON Schema of the release they implemented.

## D-003 CR-7 item 1: "fileNumber" as business name, technical name stays `reference` in 1.x (2026-11-23)
Renaming a property in a closed JSON schema breaks all three partners. Choice: label, description, glossary and DB comment say "File number" (business name fileNumber), so the clerks' UI can show that term today. The technical rename is deferred to a 2.0.0. Rejected alternative: sending both `reference` and `fileNumber` - redundant, and still rejected by 1.0.0 validators.

## D-004 CR-7 item 2: applicant optional in the schema, mandatory for new permits by rule (2026-11-23)
Part of the ~2 million legacy permits have no known applicant, so a NOT NULL column / required property is impossible without inventing data. Choice: `applicant` 0..1 in model and schema; constraint C-002 makes it mandatory for permits created from the 1.1.0 go-live, enforced by an INSERT trigger (legacy rows stay updatable). Applicant is an embedded datatype (name, organisation, Address), not a separate class: CR-7 asks for no applicant identity, reuse or de-duplication. A persistence column `created_at` was added to tell legacy from new permits; existing rows get the migration timestamp.

## D-005 CR-7 item 3: "expired" is derived, not stored (2026-11-23)
"Expired" follows entirely from status = granted and a validity end in the past. Storing it needs a scheduled job and risks inconsistency, and adding a value to the non-extensible, closed PermitStatus enum breaks partners that receive it. Choice: derived status in view `permit_effective_status` (documented as enumeration DerivedPermitStatus); exchange unchanged, receivers can derive it from transmitted fields. Revisit for 2.0.0 if partners need it transmitted.

## D-006 CR-7 item 4: separate optional `validUntilTime` instead of changing validUntil to date-time (2026-11-23)
Changing validUntil from date to date-time breaks every partner and all existing values. Choice: additional optional `validUntilTime` (local time of the issuing authority, no offset); absent means end of day, so the 1.0.0 meaning of existing data is unchanged. Local time chosen because clerks think in "expires at noon"; the time zone must be fixed (OQ-3). Consider merging into one date-time in 2.0.0.

## D-007 CR-7 item 6: keywords deprecated, not removed (2026-11-23)
Removing a property from the closed schema makes documents from partners that still send it invalid. Choice: deprecated in 1.1.0 (schema `deprecated: true`, advisory C-005); data and table kept; removal planned for 2.0.0. "Nobody uses it" is the permits team's view; partner usage is unconfirmed (OQ-4).

## D-008 1.1.0 is an additive minor release; partners opt in (2026-11-23)
All CR-7 items were implemented additively: 1.1.0 accepts every 1.0.0 document and the DB migration is non-destructive. Because partners validate closed content against the release they implemented (D-002), new properties must not be sent to a partner until it has switched to the 1.1.0 schema; until then the sender omits applicant, validUntilTime and category for that partner (a 1.1.0 document without them is a valid 1.0.0 document). No change is forced on partners.
