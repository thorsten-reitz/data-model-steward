# Decisions

## D-001 Permit identifiers are UUIDs (2026-04-02)
Permits are exchanged with three municipal partner systems. Choice: UUID, stable across systems.

## D-002 Exchange format is JSON with closed content (2026-04-10)
Partners validate strictly against the JSON Schema of the release they implemented.

## D-003 CR-7 is a minor release (1.1.0); breaking parts deferred to 2.0.0 (2026-11-23)
Three partner systems validate strictly against 1.0.0 (D-002). Of the CR-7 items, the rename (item 1), the
removal (item 6), the retyping of validUntil (item 4) and a new PermitStatus value (item 3) would each break
them. Choice: put everything that can be done additively into 1.1.0 and defer the breaking parts to a
coordinated 2.0.0.
- Item 1: `reference` keeps its technical name in the model, JSON and SQL. "File number" / `fileNumber` is
  recorded as its label, alias and glossary term, so user interfaces and documents can use the clerks' term now.
- Producers must send 1.0.0 partners the 1.0.0 projection (exports/1.1.0/compatibility.md). Because content
  is closed, even optional new properties would be rejected by a 1.0.0 validator.

Alternatives rejected: a direct 2.0.0 with all changes (breaks all three partners for a cosmetic rename);
adding `fileNumber` next to `reference` (two names for one fact, and it still breaks closed 1.0.0 validators).

## D-004 Applicant is an embedded datatype, optional in the schema, required for new permits (2026-11-23)
CR-7 asks that every permit has an applicant, but it is unknown for many of the ~2M existing permits. Making
it mandatory would mean inventing placeholder data. Choice: `Permit.applicant` 0..1, plus constraint C-002
(required on creation from the cut-over date). C-002 is enforced on INSERT only, so old permits can still be
revoked or corrected. The applicant is a value (datatype) without its own identity, which matches CR-7's
"name + optional organisation + address". The applicant can be a natural person, so the datatype is
classified `personal` (see Q-002).

## D-005 "Expired" is derived, not a stored status (2026-11-23)
"Expired" depends only on validUntil (plus time) and the current time. Storing it would need a scheduled job
to flip ~200k permits a year, and it would contradict validUntil between runs. Adding it to the closed,
non-extensible PermitStatus enum would also break 1.0.0 partners. Choice: derived attribute `Permit.expired`
(status = granted and the expiry moment has passed), shown as effective status "expired" via the view
`permit_effective_status`. It is not exchanged: partners compute it from validUntil/validUntilTime.
Revoked, refused and applied permits never become "expired".

## D-006 validUntil gets a separate optional time of day; keywords deprecated, not dropped (2026-11-23)
Changing validUntil from date to date-time would break partners and need a conversion of existing dates that
guesses the time zone. Choice: additive `validUntilTime` (local time, absent = end of day), so existing data
keeps its meaning. A merge into one date-time attribute is a 2.0.0 candidate.
`keywords` is deprecated in 1.1.0 (producers stop filling it; it is still accepted) and removed in 2.0.0.
Dropping it now would make 1.0.0 documents that contain keywords invalid, and would delete data irreversibly.

## D-007 Exports for 1.1.0 hand-written (2026-11-23)
dmtool was not available. exports/1.1.0 was written by hand in dmtool's output style. The JSON Schema was
checked with a 2020-12 validator: 1.0.0 sample documents are valid against 1.1.0, and the 1.0.0 projection of
a 1.1.0 document is valid against 1.0.0. The SQL was not run against PostgreSQL. Regenerate with dmtool and
diff before release.
