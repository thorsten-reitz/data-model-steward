# Decisions

## D-001 Permit identifiers are UUIDs (2026-04-02)
Permits are exchanged with three municipal partner systems. Choice: UUID, stable across systems.

## D-002 Exchange format is JSON with closed content (2026-04-10)
Partners validate strictly against the JSON Schema of the release they implemented.

## D-003 CR-7 is delivered as a non-breaking minor release 1.1.0 (2026-11-23)
Context: CR-7 (S2) has six items. Read literally, four are breaking (rename, new mandatory
attribute, retyping, removal), and a fifth (new value in the closed enum `PermitStatus`) breaks
the three partners that validate strictly against the 1.0.0 JSON Schema (D-002).
Options: (a) 2.0.0 with everything as requested - every partner and the database must migrate
at once; (b) 1.1.0 with the non-breaking equivalent of each item, breaking parts collected as
candidates for a later 2.0.0.
Choice: (b). Decided by the modeller on the owner's instruction ("don't break the partners
unless there's no other way"; owner unavailable). None of the six items strictly needs a
breaking change. To be confirmed by the owner (Q-001).
Note on `dmtool.py diff`: it reports constraints C-002 and C-003 as "breaking" because any new
constraint might invalidate existing data. Here it cannot: C-002 is warning-level and applies
only to permits recorded from 1.1.0 on; C-003 constrains only the new attribute
`validUntilDateTime`, which is empty in all existing data. All other changes are classified
compatible or documentation-only.

## D-004 "File number" is a business term; the attribute stays `reference` (2026-11-23)
Context: CR-7 item 1 asks to rename `reference` to `fileNumber` "everywhere".
Options: (a) rename - breaking for all partners and the database; (b) add `fileNumber` and
deprecate `reference` - the usual non-breaking route, but `reference` is mandatory and unique,
so both would have to be carried with identical values, and with closed content the extra
property still breaks 1.0.0 validators; (c) keep `reference` as the technical/exchange name and
adopt "file number" as the business term (description, glossary, DB comment, UI labels).
Choice: (c). The meaning does not change (1.0.0 already defined it as the file number), so the
request is about vocabulary, which (c) delivers at no cost. The physical rename is listed as a
2.0.0 candidate (Q-001).

## D-005 Applicant as optional, voidable value on Permit (2026-11-23)
Context: CR-7 item 2 wants a mandatory applicant, but the applicant of many of the ~2 million
existing permits is unknown.
Choice: new datatype `Applicant` (name, organisation 0..1, address: `Address`) and attribute
`Permit.applicant` 0..1, voidable. "Mandatory for new permits" becomes warning-level rule C-002
(documented, enforced by the producing applications, not by the schemas). A schema-mandatory
applicant would break all existing data and all partners; even in 2.0.0 it can only become
"1, voidable" (explicit null = unknown), because old applicants stay unknown.
Datatype rather than class: CR-7 only asks for name/organisation/address per permit; there is
no requirement for applicant identity, de-duplication or search by applicant (Q-003).
Consequence: Permit now holds personal data; `nfr.classification` raised to `personal` (Q-004).
Max lengths copied from `Authority.name` / `Address` (A-003).

## D-006 "Expired" is a derived state, not a new PermitStatus value (2026-11-23)
Context: CR-7 item 3. Adding `expired` to the closed enum counts as "minor" by the model rules,
but the three partners reject unknown enum values, so the first expired permit sent to them
would fail validation. A stored, time-dependent status also needs a job that flips statuses
(with versioned history: a new version for every permit that expires), and it hides whether the
permit had been granted.
Choice: expiry is derived - expired = status `granted` and validity end passed (Permit notes).
The database exposes it in view `permit_registry.permit_with_expiry` (`expired`,
`effective_status`), exports/1.1.0/views.sql. Partners compute it from fields they already
receive. Alternative for the owner: a real `expired` status in a coordinated release (Q-002).

## D-007 Validity end with time of day: new attribute `validUntilDateTime` (2026-11-23)
Context: CR-7 item 4. Retyping `validUntil` from date to dateTime breaks data and consumers.
Choice: add `validUntilDateTime` (dateTime with UTC offset, 0..1, voidable); deprecate
`validUntil` (`replacedBy: validUntilDateTime`) but keep populating it with the local calendar
date (rule C-003) so 1.0.0 consumers keep working. Validity ends exclusive of the instant
("valid up to, not including"). No automatic backfill for existing permits (Q-005).
dateTime rather than a separate time-of-day attribute so the UTC offset is explicit.

## D-008 Condition category as optional, extensible code list (2026-11-23)
Context: CR-7 item 5; existing conditions have no category.
Choice: enumeration `ConditionCategory` (environmental, safety, other), `extensible: true`,
maintained by the permits team; `PermitCondition.category` 0..1. Extensible so that future
categories need no model release and are not rejected by partners' validators (lesson from
D-006); exported as open string (JSON/XSD) and lookup table (PostgreSQL). Optional because
existing conditions are unclassified (Q-008).

## D-009 `keywords` deprecated, not removed (2026-11-23)
Context: CR-7 item 6. Removal is breaking: partners on 1.0.0 may still send or read it.
Choice: deprecate in 1.1.0; producers stop populating it (absent/empty is valid in 1.0.0 too);
remove in the next major release (Q-001). DB table `permit_keywords` is kept until then.

## D-010 Exchange rollout: per-partner schema version, closed content kept (2026-11-23)
Context: with closed content (D-002) every new property - even an optional one - makes a
document invalid for a partner validating against 1.0.0. Verified with jsonschema:
exports/1.1.0/examples/permit-1.1.0-full.json fails the 1.0.0 schema;
permit-1.1.0-for-1.0.0-partners.json is valid against both 1.0.0 and 1.1.0.
Choice: until a partner has moved to 1.1.0, documents sent to it omit the 1.1.0-only properties
(`applicant`, `validUntilDateTime`, `conditions[].category`); `reference` and `validUntil` stay
populated. Closed content is not changed in 1.1.0 (that change itself needs partner agreement,
Q-007).

## D-011 XSD export generated from 1.1.0 on (2026-11-23)
`model.targets` lists `xsd`, but no XSD existed for 1.0.0. Generated with dmtool for 1.1.0
(parses as a valid XML Schema with lxml; geometry is an `xs:anyType` placeholder, GML import
not done).
