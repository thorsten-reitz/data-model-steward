# Glossary

- **Permit**: official authorisation.
- **File number**: the number under which the authority handles a permit; the term the clerks use (S2).
  Modelled as `Permit.reference` - the technical/exchange name is kept for compatibility (D-004).
  Synonyms: reference, case number. Use "file number" in UIs and documentation for clerks.
- **Applicant**: person or organisation that applied for a permit (name, optional organisation, address). Since 1.1.0 (S2, D-005).
- **Expired**: a *granted* permit whose validity end has passed. A derived state, not a stored
  `PermitStatus` value (D-006). A refused or revoked permit is never "expired".
- **Validity end**: `validUntilDateTime` (exact instant, since 1.1.0); for older permits the end of
  the `validUntil` day in local time. The permit is valid up to, not including, that instant.
- **Condition category**: classification of a permit condition - environmental, safety, other (S2, D-008).
- Not used: **keywords** (deprecated in 1.1.0, D-009).
